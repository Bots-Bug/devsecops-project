#!/bin/bash
# Jenkins Master — minimal bootstrap for Ansible
# Ansible will install Java, Jenkins, mount EFS, configure service

exec > /var/log/userdata.log 2>&1
echo "=== Master bootstrap started: $(date) ==="

# Wait for yum lock
while fuser /var/run/yum.pid >/dev/null 2>&1; do
  echo "Waiting for yum lock..."
  sleep 5
done

yum update -y

# Python3 is required for Ansible to manage this host
# Amazon Linux 2 has Python 3 available, but ensure pip3 is present
yum install -y python3 nfs-utils amazon-efs-utils wget curl git

# Disable firewalld — EC2 Security Groups handle access control
systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo "=== Master bootstrap complete: $(date) ==="
echo "Waiting for Ansible to complete configuration..."