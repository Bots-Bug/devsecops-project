#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# Jenkins Master — User Data Script
# OS: Amazon Linux 2 (RHEL-compatible)
#
# Terraform template variables (injected at apply time):
#   ${efs_id}              — EFS filesystem ID
#   ${efs_access_point_id} — EFS access point ID
#   ${aws_region}          — AWS region
#   ${environment}         — prod / staging / dev
#   ${project}             — jenkins
#   ${backups_bucket}      — S3 bucket name for backups
#
# Shell variables use $$ prefix so Terraform does not misinterpret them:
#   $$VAR   → becomes $VAR  in the actual script on the EC2 instance
#   $$(cmd) → becomes $(cmd) in the actual script
# ─────────────────────────────────────────────────────────────────────────

set -euxo pipefail

# ── Terraform-injected values (no $$ needed here — these are template vars) ─
EFS_ID="${efs_id}"
EFS_AP_ID="${efs_access_point_id}"
AWS_REGION="${aws_region}"
BACKUPS_BUCKET="${backups_bucket}"
JENKINS_HOME="/var/lib/jenkins"

# ── System Update ──────────────────────────────────────────────────────────
yum update -y

# ── Install Base Packages ─────────────────────────────────────────────────
yum install -y \
  curl \
  git \
  jq \
  unzip \
  wget \
  nfs-utils \
  amazon-efs-utils

# ── Install Java 17 via amazon-linux-extras ────────────────────────────────
# amazon-linux-extras is the RHEL-compatible way on Amazon Linux 2
# Jenkins LTS requires Java 11 or 17. We use 17 (LTS).
amazon-linux-extras enable corretto17
yum install -y java-17-amazon-corretto-headless

# Verify Java
java -version

# ── Install AWS CLI v2 ────────────────────────────────────────────────────
# Amazon Linux 2 ships with AWS CLI v1 — replace with v2 for full feature set
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# ── Create Jenkins User ────────────────────────────────────────────────────
# Jenkins RPM creates this user but we create it early so UID is predictable
# Amazon Linux 2: jenkins user gets UID 997 from the RPM
# EFS access point is configured with UID 997 to match
id jenkins &>/dev/null || useradd -m -r -u 997 -s /sbin/nologin jenkins

# ── Mount EFS ─────────────────────────────────────────────────────────────
mkdir -p "$$JENKINS_HOME"

# amazon-efs-utils handles TLS mount and retries automatically
mount -t efs \
  -o tls,accesspoint="$$EFS_AP_ID" \
  "$$EFS_ID:/" \
  "$$JENKINS_HOME"

# Persist across reboots
echo "$$EFS_ID:/ $$JENKINS_HOME efs tls,accesspoint=$$EFS_AP_ID,_netdev 0 0" \
  >> /etc/fstab

# Set ownership after mount so it writes to EFS, not local disk
chown -R jenkins:jenkins "$$JENKINS_HOME"

# ── Install Jenkins LTS ────────────────────────────────────────────────────
# Add Jenkins stable yum repository
wget -q -O /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo

rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

yum install -y jenkins

# Stop immediately — configure before first start
systemctl stop jenkins || true

# ── Configure Jenkins Systemd Service ─────────────────────────────────────
mkdir -p /etc/systemd/system/jenkins.service.d/

cat > /etc/systemd/system/jenkins.service.d/override.conf <<'OVERRIDE'
[Service]
Environment="JENKINS_HOME=/var/lib/jenkins"
Environment="JAVA_OPTS=-Xmx2g -Xms512m -Djava.awt.headless=true -Duser.timezone=UTC"
Environment="JENKINS_PORT=8080"
OVERRIDE

# ── Pre-install Essential Plugins ─────────────────────────────────────────
# Using plugin installation manager — faster and more reliable than wizard
# Jenkins setup wizard will still run but plugins are already there

PLUGIN_MGR_VER="2.13.0"
wget -q "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/$${PLUGIN_MGR_VER}/jenkins-plugin-manager-$${PLUGIN_MGR_VER}.jar" \
  -O /opt/jenkins-plugin-manager.jar

cat > /tmp/plugins.txt <<'PLUGINS'
workflow-aggregator:latest
git:latest
role-strategy:latest
credentials:latest
credentials-binding:latest
ssh-credentials:latest
plain-credentials:latest
aws-credentials:latest
aws-secrets-manager-credentials-provider:latest
ssh-agent:latest
mailer:latest
timestamper:latest
build-timeout:latest
ws-cleanup:latest
pipeline-stage-view:latest
audit-trail:latest
pipeline-utility-steps:latest
antisamy-markup-formatter:latest
PLUGINS

java -jar /opt/jenkins-plugin-manager.jar \
  --war /usr/share/jenkins/jenkins.war \
  --plugin-download-directory "$$JENKINS_HOME/plugins" \
  --plugin-file /tmp/plugins.txt \
  --verbose || echo "WARNING: Some plugins failed — install via UI"

chown -R jenkins:jenkins "$$JENKINS_HOME"

# ── Backup Cron Job ────────────────────────────────────────────────────────
cat > /usr/local/bin/jenkins-backup.sh <<'BACKUPSCRIPT'
#!/bin/bash
# Backs up Jenkins config (not builds — those are in Git)
set -e
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JENKINS_HOME="/var/lib/jenkins"
BACKUP_BUCKET="BUCKET_PLACEHOLDER"
AWS_REGION="REGION_PLACEHOLDER"

tar czf /tmp/jenkins-config-$${TIMESTAMP}.tar.gz \
  -C "$${JENKINS_HOME}" \
  --exclude='workspace' \
  --exclude='builds' \
  --exclude='logs' \
  --exclude='caches' \
  jobs users config.xml credentials.xml 2>/dev/null || true

aws s3 cp /tmp/jenkins-config-$${TIMESTAMP}.tar.gz \
  "s3://$${BACKUP_BUCKET}/jenkins-backups/$${TIMESTAMP}/jenkins-config.tar.gz" \
  --region "$${AWS_REGION}"

rm -f /tmp/jenkins-config-$${TIMESTAMP}.tar.gz
echo "Backup done: $${TIMESTAMP}"
BACKUPSCRIPT

# Replace placeholders in the backup script with actual values
sed -i "s|BUCKET_PLACEHOLDER|$$BACKUPS_BUCKET|g" /usr/local/bin/jenkins-backup.sh
sed -i "s|REGION_PLACEHOLDER|$$AWS_REGION|g" /usr/local/bin/jenkins-backup.sh
chmod +x /usr/local/bin/jenkins-backup.sh

# Run daily at 2 AM
echo "0 2 * * * jenkins /usr/local/bin/jenkins-backup.sh >> /var/log/jenkins/backup.log 2>&1" \
  > /etc/cron.d/jenkins-backup

# ── Start Jenkins ──────────────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable jenkins
systemctl start jenkins

# ── Wait for Jenkins to Respond ────────────────────────────────────────────
echo "Waiting for Jenkins to start (max 5 minutes)..."
ATTEMPT=0
until curl -sf http://localhost:8080/login > /dev/null 2>&1; do
  ATTEMPT=$$((ATTEMPT + 1))
  if [ "$$ATTEMPT" -ge 60 ]; then
    echo "ERROR: Jenkins did not start within 5 minutes. Check: journalctl -u jenkins"
    exit 1
  fi
  echo "Attempt $$ATTEMPT/60 — still waiting..."
  sleep 5
done

echo "============================================================"
echo " Jenkins is UP"
echo " Initial admin password:"
echo "   sudo cat /var/lib/jenkins/secrets/initialAdminPassword"
echo "============================================================"