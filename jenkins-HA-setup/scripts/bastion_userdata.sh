#!/bin/bash
# Bastion bootstrap — installs Ansible and dependencies
# Ansible will be run manually from this host to configure master + agents

exec > /var/log/bastion-userdata.log 2>&1
echo "=== Bastion bootstrap started: $(date) ==="

# Wait for yum lock
while fuser /var/run/yum.pid >/dev/null 2>&1; do
  echo "Waiting for yum lock..."
  sleep 5
done

yum update -y
yum install -y python3 python3-pip git wget curl jq unzip

# Install Ansible and AWS libraries
pip3 install --upgrade pip
pip3 install ansible boto3 botocore

# Install Amazon.aws Ansible collection (provides aws_ec2 inventory plugin)
ansible-galaxy collection install amazon.aws --force

echo "Ansible version: $(ansible --version | head -1)"
echo "Boto3 version: $(python3 -c 'import boto3; print(boto3.__version__)')"

# Create directory for ansible repo
mkdir -p /opt/ansible
chown ec2-user:ec2-user /opt/ansible

echo "=== Bastion bootstrap complete: $(date) ==="
echo ""
echo "Next steps:"
echo "  1. SSH to bastion with agent forwarding: ssh -A ec2-user@<bastion-ip>"
echo "  2. Clone your repo: git clone <your-repo> /opt/ansible"
echo "  3. cd /opt/ansible/jenkins-HA-setup/ansible"
echo "  4. ansible-playbook playbooks/site.yml"