#!/bin/bash
# Jenkins Linux Agent — minimal bootstrap for Ansible

exec > /var/log/userdata.log 2>&1
echo "=== Agent bootstrap started: $(date) ==="

while fuser /var/run/yum.pid >/dev/null 2>&1; do
  echo "Waiting for yum lock..."
  sleep 5
done

yum update -y
yum install -y python3 wget curl git jq unzip

systemctl stop firewalld 2>/dev/null || true
systemctl disable firewalld 2>/dev/null || true

echo "=== Agent bootstrap complete: $(date) ==="