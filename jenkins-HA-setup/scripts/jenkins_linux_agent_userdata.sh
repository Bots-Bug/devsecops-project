#!/bin/bash
exec > /var/log/jenkins-agent-userdata.log 2>&1
set -e

echo "=== Jenkins Linux Agent UserData started: $(date) ==="

MASTER_IP="${jenkins_master_private_ip}"
AWS_REGION="${aws_region}"
ENVIRONMENT="${environment}"
AGENT_NUMBER="${agent_number}"
AGENT_NAME="linux-agent-$AGENT_NUMBER"
AGENT_HOME="/home/jenkins-agent"

JAVA_HOME="/opt/java/amazon-corretto-21.0.11.10.1-linux-x64"

echo "MASTER_IP  = $MASTER_IP"
echo "AGENT_NAME = $AGENT_NAME"

# ── STEP 1: Base packages ────────────────────────────────────────────────
yum update -y

# 🔥 IMPORTANT: includes fonts + awscli
yum install -y git wget curl jq unzip tar \
               nfs-utils amazon-efs-utils awscli \
               fontconfig dejavu-sans-fonts

# ── STEP 2: Install Java 21 ──────────────────────────────────────────────
echo "=== Installing Java 21 ==="

mkdir -p /opt/java
cd /opt/java

wget -q https://corretto.aws/downloads/resources/21.0.11.10.1/amazon-corretto-21.0.11.10.1-linux-x64.tar.gz
tar -xzf amazon-corretto-21.0.11.10.1-linux-x64.tar.gz
rm -f amazon-corretto-21.0.11.10.1-linux-x64.tar.gz

echo "export JAVA_HOME=$JAVA_HOME" >> /etc/profile
echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile
export PATH=$JAVA_HOME/bin:$PATH

java -version

# ── STEP 3: Create user safely ───────────────────────────────────────────
echo "=== Creating agent user ==="

if ! id "jenkins-agent" &>/dev/null; then
  useradd -m -s /bin/bash jenkins-agent
fi

mkdir -p $AGENT_HOME/workspace
chown -R jenkins-agent:jenkins-agent $AGENT_HOME

# ── STEP 4: Disable firewall ─────────────────────────────────────────────
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

# ── STEP 5: Wait for Jenkins master ──────────────────────────────────────
echo "=== Waiting for Jenkins master ==="

ATTEMPT=1
MASTER_READY=false

while [ $ATTEMPT -le 90 ]; do
  if curl -sf "http://$MASTER_IP:8080/login" > /dev/null 2>&1; then
    MASTER_READY=true
    echo "Master is reachable"
    break
  fi
  echo "Waiting for master ($ATTEMPT/90)..."
  ATTEMPT=$((ATTEMPT + 1))
  sleep 10
done

if [ "$MASTER_READY" != "true" ]; then
  echo "ERROR: Jenkins master not reachable"
  exit 1
fi

# ── STEP 6: Download agent.jar ───────────────────────────────────────────
echo "=== Downloading agent.jar ==="

curl -f "http://$MASTER_IP:8080/jnlpJars/agent.jar" \
  -o $AGENT_HOME/agent.jar

chown jenkins-agent:jenkins-agent $AGENT_HOME/agent.jar

# ── STEP 7: Fetch agent secret ───────────────────────────────────────────
echo "=== Fetching agent secret ==="

AGENT_SECRET=""
ATTEMPT=1

while [ $ATTEMPT -le 120 ]; do
  AGENT_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "jenkins-$ENVIRONMENT/agents/$AGENT_NAME/secret" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text 2>/dev/null | jq -r '.secret // empty' 2>/dev/null || echo "")

  if [ -n "$AGENT_SECRET" ]; then
    echo "Secret retrieved"
    break
  fi

  echo "Waiting for secret ($ATTEMPT/120)..."
  ATTEMPT=$((ATTEMPT + 1))
  sleep 30
done

if [ -z "$AGENT_SECRET" ]; then
  echo "ERROR: Failed to retrieve agent secret"
  exit 1
fi

# ── STEP 8: Systemd service ──────────────────────────────────────────────
echo "=== Creating systemd service ==="

cat > /etc/systemd/system/jenkins-agent.service <<EOF
[Unit]
Description=Jenkins Agent $AGENT_NAME
After=network-online.target

[Service]
User=jenkins-agent
WorkingDirectory=$AGENT_HOME
Environment="JAVA_HOME=$JAVA_HOME"
ExecStart=$JAVA_HOME/bin/java -jar $AGENT_HOME/agent.jar \\
  -url http://$MASTER_IP:8080/ \\
  -name $AGENT_NAME \\
  -secret $AGENT_SECRET \\
  -workDir $AGENT_HOME/workspace
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ── STEP 9: Start agent ──────────────────────────────────────────────────
echo "=== Starting Jenkins agent ==="

systemctl daemon-reload
systemctl enable jenkins-agent
systemctl start jenkins-agent

sleep 5
systemctl status jenkins-agent --no-pager || true

echo ""
echo "============================================================"
echo " Jenkins Agent setup COMPLETE: $(date)"
echo " Agent Name: $AGENT_NAME"
echo "============================================================"