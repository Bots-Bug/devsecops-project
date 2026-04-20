#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# Jenkins Linux Agent — User Data Script
# OS: Amazon Linux 2
#
# Terraform template variables:
#   ${jenkins_master_private_ip} — private IP of Jenkins master
#   ${aws_region}                — AWS region
#   ${environment}               — environment name
#   ${agent_number}              — 1, 2, 3 etc.
#
# Shell variables: $$ prefix (becomes $ on the EC2 instance)
# ─────────────────────────────────────────────────────────────────────────

set -euxo pipefail

MASTER_IP="${jenkins_master_private_ip}"
AWS_REGION="${aws_region}"
ENVIRONMENT="${environment}"
AGENT_NUMBER="${agent_number}"
AGENT_NAME="linux-agent-$$AGENT_NUMBER"
AGENT_HOME="/home/jenkins-agent"

# ── System Update & Packages ──────────────────────────────────────────────
yum update -y
yum install -y \
  curl \
  git \
  jq \
  unzip \
  wget \
  java-17-amazon-corretto-headless

# Install Java (same as master)
amazon-linux-extras enable corretto17 || true
yum install -y java-17-amazon-corretto-headless

# AWS CLI v2
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# ── Create Agent User ─────────────────────────────────────────────────────
useradd -m -u 1500 -s /bin/bash jenkins-agent || true
mkdir -p "$$AGENT_HOME/workspace"
chown -R jenkins-agent:jenkins-agent "$$AGENT_HOME"

# ── Wait for Jenkins Master ────────────────────────────────────────────────
echo "Waiting for Jenkins master at $$MASTER_IP..."
ATTEMPT=0
until curl -sf "http://$$MASTER_IP:8080/login" > /dev/null 2>&1; do
  ATTEMPT=$$((ATTEMPT + 1))
  if [ "$$ATTEMPT" -ge 60 ]; then
    echo "ERROR: Jenkins master not reachable after 5 minutes"
    exit 1
  fi
  echo "Attempt $$ATTEMPT/60 — waiting for master..."
  sleep 5
done

# ── Download Agent JAR ────────────────────────────────────────────────────
curl -sf "http://$$MASTER_IP:8080/jnlpJars/agent.jar" \
  -o "$$AGENT_HOME/agent.jar"
chown jenkins-agent:jenkins-agent "$$AGENT_HOME/agent.jar"

# ── Fetch Agent Secret from Secrets Manager ───────────────────────────────
# The secret is stored here AFTER Jenkins master creates the node.
# This script polls every 30 seconds until the secret is available.
# To populate: see Step 10 in the setup guide.
#
# SECRET PATH: jenkins-{env}/agents/{agent-name}/secret
# SCALE NOTE: if you add more agents, the secret path uses the agent name
#             which matches the node name you create in Jenkins UI

AGENT_SECRET=""
ATTEMPT=0
while [ -z "$$AGENT_SECRET" ]; do
  ATTEMPT=$$((ATTEMPT + 1))
  if [ "$$ATTEMPT" -ge 60 ]; then
    echo "Agent secret not found after 30 minutes. Service will start without it."
    echo "Manually run: systemctl start jenkins-agent after storing the secret."
    break
  fi

  AGENT_SECRET=$$(aws secretsmanager get-secret-value \
    --secret-id "jenkins-$$ENVIRONMENT/agents/$$AGENT_NAME/secret" \
    --region "$$AWS_REGION" \
    --query SecretString \
    --output text 2>/dev/null | jq -r '.secret // empty' 2>/dev/null || echo "")

  if [ -z "$$AGENT_SECRET" ]; then
    echo "Attempt $$ATTEMPT/60 — secret not yet available, waiting 30s..."
    sleep 30
  fi
done

# ── Create Systemd Service for Agent ──────────────────────────────────────
cat > /etc/systemd/system/jenkins-agent.service <<SVCFILE
[Unit]
Description=Jenkins Agent $$AGENT_NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=jenkins-agent
Group=jenkins-agent
WorkingDirectory=$$AGENT_HOME
ExecStart=/usr/bin/java \
  -jar $$AGENT_HOME/agent.jar \
  -url http://$$MASTER_IP:8080/ \
  -name $$AGENT_NAME \
  -secret $$AGENT_SECRET \
  -workDir $$AGENT_HOME/workspace \
  -failIfWorkDirIsMissing
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
SVCFILE

systemctl daemon-reload

if [ -n "$$AGENT_SECRET" ]; then
  systemctl enable jenkins-agent
  systemctl start jenkins-agent
  echo "Jenkins agent $$AGENT_NAME started."
else
  echo "Systemd service created. Start manually after storing the secret:"
  echo "  systemctl start jenkins-agent"
fi