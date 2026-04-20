aws_region  = "us-east-1"
project     = "jenkins"
environment = "prod"

vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]
availability_zones   = ["us-east-1a", "us-east-1b"]

# ── For POC: allow your office/home IP only ───────────────────────────────
# Find your public IP: https://checkip.amazonaws.com
# Replace the value below with your actual IP in CIDR format e.g. "203.0.113.5/32"
# For fully open access during POC (not recommended for long term): "0.0.0.0/0"
corporate_ip_ranges = ["0.0.0.0/0"]

# ── No ACM needed — HTTP only for POC ────────────────────────────────────
acm_certificate_arn = ""

# ── EC2 key pair name (must exist in AWS before apply) ────────────────────
key_name = "jenkins-prod-keypair"

# ── LDAP not configured yet ───────────────────────────────────────────────
ldap_server_url     = "ldap://placeholder:389"
jenkins_admin_email = "your-email@example.com"

# ── POC sizing: t3.medium for master, t3.small for agents ─────────────────
# ENTERPRISE SIZING (comment above, uncomment below when going to production):
#   jenkins_master_instance_type = "m5.xlarge"    # 4 vCPU 16GB
#   jenkins_agent_instance_type  = "t3.large"     # 2 vCPU 8GB
jenkins_master_instance_type = "t3.medium"  # 2 vCPU 4GB — fine for POC
jenkins_agent_instance_type  = "t3.small"   # 2 vCPU 2GB — fine for light builds

# ── 1 Linux agent for POC ─────────────────────────────────────────────────
# SCALE UP: increase this number when you need more parallel builds
# DYNAMIC SCALING: replace static agents with EC2 Fleet plugin (see comments in compute/main.tf)
linux_agent_count = 1