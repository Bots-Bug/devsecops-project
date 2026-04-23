#!/bin/bash
exec > /var/log/jenkins-userdata.log 2>&1
set -e

echo "=== Jenkins Master UserData started: $(date) ==="

EFS_ID="${efs_id}"
EFS_AP_ID="${efs_access_point_id}"
AWS_REGION="${aws_region}"
BACKUPS_BUCKET="${backups_bucket}"
JENKINS_HOME="/var/lib/jenkins"
JAVA_HOME="/opt/java/amazon-corretto-21.0.11.10.1-linux-x64"

# Wait for yum lock
while fuser /var/run/yum.pid >/dev/null 2>&1; do
  echo "Waiting for yum lock..."
  sleep 5
done

# ── STEP 1: Base packages ────────────────────────────────────────────────
echo "=== STEP 1: Base packages ==="
yum update -y

#  Includes FONT FIX + AWS CLI
yum install -y git wget curl jq unzip tar nfs-utils amazon-efs-utils \
               fontconfig dejavu-sans-fonts awscli

# ── STEP 2: Java 21 ─────────────────────────────────────────────────────
echo "=== STEP 2: Java 21 ==="
mkdir -p /opt/java
cd /opt/java

wget -q https://corretto.aws/downloads/resources/21.0.11.10.1/amazon-corretto-21.0.11.10.1-linux-x64.tar.gz
tar -xzf amazon-corretto-21.0.11.10.1-linux-x64.tar.gz
rm -f amazon-corretto-21.0.11.10.1-linux-x64.tar.gz

echo "export JAVA_HOME=$JAVA_HOME" >> /etc/profile
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile
export PATH=$JAVA_HOME/bin:$PATH

java -version

# ── STEP 3: Jenkins WAR ──────────────────────────────────────────────────
echo "=== STEP 3: Download Jenkins WAR ==="
mkdir -p /opt/jenkins
wget -q https://get.jenkins.io/war-stable/latest/jenkins.war -O /opt/jenkins/jenkins.war

# ── STEP 4: Jenkins user (safe) ──────────────────────────────────────────
echo "=== STEP 4: Create jenkins user ==="
if ! id "jenkins" &>/dev/null; then
  useradd -m -d $JENKINS_HOME -s /bin/bash jenkins
fi
id jenkins

# ── STEP 5: Mount EFS ────────────────────────────────────────────────────
echo "=== STEP 5: Mount EFS ==="
mkdir -p $JENKINS_HOME

ATTEMPT=1
EFS_READY=false

while [ $ATTEMPT -le 18 ]; do
  echo "EFS mount attempt $ATTEMPT..."
  if mount -t efs -o tls,accesspoint=$EFS_AP_ID $EFS_ID:/ $JENKINS_HOME; then
    EFS_READY=true
    echo "EFS mounted"
    break
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 10
done

if [ "$EFS_READY" = "true" ]; then
  echo "$EFS_ID:/ $JENKINS_HOME efs tls,accesspoint=$EFS_AP_ID,_netdev 0 0" >> /etc/fstab
else
  echo "WARNING: EFS mount failed — using local disk"
fi

chown -R jenkins:jenkins $JENKINS_HOME
chown -R jenkins:jenkins /opt/jenkins

# ── STEP 6: Systemd service ──────────────────────────────────────────────
echo "=== STEP 6: Systemd service ==="
cat > /etc/systemd/system/jenkins.service <<EOF
[Unit]
Description=Jenkins CI
After=network.target

[Service]
User=jenkins
Group=jenkins
WorkingDirectory=/opt/jenkins
Environment="JAVA_HOME=$JAVA_HOME"
Environment="JENKINS_HOME=$JENKINS_HOME"
ExecStart=$JAVA_HOME/bin/java \\
  -Xmx2g -Xms512m \\
  -Djava.awt.headless=true \\
  -Duser.timezone=UTC \\
  -jar /opt/jenkins/jenkins.war \\
  --httpPort=8080
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ── STEP 7: Disable firewall ─────────────────────────────────────────────
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

# ── STEP 8: Start Jenkins ────────────────────────────────────────────────
echo "=== STEP 8: Start Jenkins ==="
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

# ── STEP 9: Wait for Jenkins ─────────────────────────────────────────────
echo "=== STEP 9: Wait for Jenkins UI ==="
for i in {1..60}; do
  if curl -sf http://localhost:8080/login > /dev/null; then
    echo "Jenkins is UP"
    break
  fi
  sleep 5
done

# ── STEP 10: Backup Script ───────────────────────────────────────────────
echo "=== STEP 10: Setup Backup ==="

cat > /usr/local/bin/jenkins-backup.sh <<'BACKUPSCRIPT'
#!/bin/bash

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JENKINS_HOME="/var/lib/jenkins"
BACKUP_BUCKET="BUCKET_PLACEHOLDER"
AWS_REGION="REGION_PLACEHOLDER"

tar czf /tmp/jenkins-config-$TIMESTAMP.tar.gz \
  -C "$JENKINS_HOME" jobs users config.xml credentials.xml 2>/dev/null || true

aws s3 cp /tmp/jenkins-config-$TIMESTAMP.tar.gz \
  "s3://$BACKUP_BUCKET/jenkins-backups/$TIMESTAMP/jenkins-config.tar.gz" \
  --region "$AWS_REGION"

rm -f /tmp/jenkins-config-$TIMESTAMP.tar.gz
BACKUPSCRIPT

sed -i "s|BUCKET_PLACEHOLDER|$BACKUPS_BUCKET|g" /usr/local/bin/jenkins-backup.sh
sed -i "s|REGION_PLACEHOLDER|$AWS_REGION|g" /usr/local/bin/jenkins-backup.sh
chmod +x /usr/local/bin/jenkins-backup.sh

echo "0 2 * * * jenkins /usr/local/bin/jenkins-backup.sh >> /var/log/jenkins-backup.log 2>&1" \
> /etc/cron.d/jenkins-backup

echo ""
echo "============================================================"
echo " Jenkins setup COMPLETE: $(date)"
echo " Access: http://<EC2-IP>:8080"
echo " Admin password:"
echo " sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
echo "============================================================"