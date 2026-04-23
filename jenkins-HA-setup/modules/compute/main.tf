locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─────────────────────────────────────────────────────────────────────────────
# AMI: Amazon Linux 2
# Why Amazon Linux 2 instead of RHEL:
#   - RHEL-compatible (same yum/rpm ecosystem)
#   - No licensing cost
#   - SSM agent pre-installed
#   - AWS-optimized kernel and drivers
# ─────────────────────────────────────────────────────────────────────────────

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "windows_2022" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# EFS: Jenkins Home
# Jenkins home is on EFS so if the EC2 instance is replaced,
# all jobs/config/credentials survive — no data loss.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_efs_file_system" "jenkins_home" {
  creation_token   = "${local.name_prefix}-jenkins-home"
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true
  kms_key_id       = var.kms_key_arn

  tags = merge(var.common_tags, {
    Name    = "${local.name_prefix}-jenkins-home"
    Purpose = "jenkins-home-directory"
  })
}

resource "aws_efs_backup_policy" "jenkins_home" {
  file_system_id = aws_efs_file_system.jenkins_home.id
  backup_policy {
    status = "ENABLED"
  }
}

# One mount target per private subnet (one per AZ)
resource "aws_efs_mount_target" "jenkins_home" {
  count           = length(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.jenkins_home.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [var.efs_sg_id]
}

resource "aws_efs_access_point" "jenkins" {
  file_system_id = aws_efs_file_system.jenkins_home.id



  root_directory {
    path = "/jenkins"
    creation_info {
      owner_uid   = 0
      owner_gid   = 0
      permissions = "755"
    }
  }

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-efs-ap"
  })
}

resource "aws_backup_selection" "jenkins_efs" {
  name         = "${local.name_prefix}-efs-selection"
  plan_id      = var.backup_plan_id
  iam_role_arn = var.backup_role_arn
  resources    = [aws_efs_file_system.jenkins_home.arn]
}

# ─────────────────────────────────────────────────────────────────────────────
# Bastion Host
# Used for SSH access to private instances for debugging
# For POC: t3.micro is fine
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = "t3.micro"  # smallest — bastion does nothing heavy
  subnet_id                   = var.public_subnet_ids[0]
  vpc_security_group_ids      = [var.bastion_sg_id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # enforce IMDSv2
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 10
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    # Disable password auth — key only
    sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    systemctl restart sshd
  EOF

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-bastion"
    Role = "bastion"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Master
#
# POC:        t3.medium  (2 vCPU, 4 GB)  ← current
# Production: m5.xlarge  (4 vCPU, 16 GB) ← change var.jenkins_master_instance_type
#
# Jenkins itself needs ~1.5 GB. With 4 GB you have room for JVM + OS.
# If builds run on agents (numExecutors=0 on master), master RAM is sufficient.
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins_master" {
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.jenkins_master_instance_type
  subnet_id                   = var.private_subnet_ids[0]
  vpc_security_group_ids      = [var.jenkins_master_sg_id]
  iam_instance_profile        = var.jenkins_master_profile
  key_name                    = var.key_name
  associate_public_ip_address = false  # master is ALWAYS private — ALB is the front door

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = false  # keep root on termination for debug
  }

  user_data = templatefile("${path.module}/../../scripts/jenkins_master_userdata.sh", {
    efs_id              = aws_efs_file_system.jenkins_home.id
    efs_access_point_id = aws_efs_access_point.jenkins.id
    aws_region          = var.aws_region
    environment         = var.environment
    project             = var.project
    backups_bucket      = var.backups_bucket_name
  })

  depends_on = [aws_efs_mount_target.jenkins_home]

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-master"
    Role = "jenkins-master"
  })

  lifecycle {
    # Prevent accidental replacement — Jenkins master holds state
    # To force replace: terraform taint module.compute.aws_instance.jenkins_master
    ignore_changes = [ami, user_data]
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Linux Agent
#
# POC:        1 agent, t3.small (2 vCPU, 2 GB)   ← current
# Production: 2+ agents, t3.large (2 vCPU, 8 GB) ← change linux_agent_count + instance_type
#
# DYNAMIC SCALING OPTION (future):
#   Replace this static resource with the EC2 Fleet Plugin in Jenkins.
#   Jenkins auto-provisions agents on demand and terminates them when idle.
#   Steps to enable later:
#     1. Install plugin: "EC2 Fleet Plugin" or "Amazon EC2 Plugin"
#     2. Create a Launch Template for agent AMI in AWS
#     3. Configure a Cloud in Jenkins: Manage Jenkins → Clouds → Add EC2 Fleet
#     4. Remove this aws_instance.jenkins_linux_agent resource from Terraform
#   Benefit: you only pay for agents when builds are running
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins_linux_agent" {
  # SCALE UP: change linux_agent_count in terraform.tfvars (e.g. 2, 3, 4)
  count                       = var.linux_agent_count
  ami                         = data.aws_ami.amazon_linux_2.id
  instance_type               = var.jenkins_agent_instance_type
  subnet_id                   = var.private_subnet_ids[count.index % length(var.private_subnet_ids)]
  vpc_security_group_ids      = [var.jenkins_linux_agent_sg_id]
  iam_instance_profile        = var.jenkins_agent_profile
  key_name                    = var.key_name
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/../../scripts/jenkins_linux_agent_userdata.sh", {
    jenkins_master_private_ip = aws_instance.jenkins_master.private_ip
    aws_region                = var.aws_region
    environment               = var.environment
    agent_number              = count.index + 1
  })

  depends_on = [aws_instance.jenkins_master]

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-linux-agent-${count.index + 1}"
    Role = "jenkins-agent-linux"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Windows Agent
#
# POC:        1 agent, t3.small  ← current
# Production: t3.large or t3.xlarge for .NET/MSBuild workloads
#
# NOTE: Windows agents are expensive to run idle.
# For production, consider:
#   - Stopping the instance outside business hours (Lambda + EventBridge schedule)
#   - Using EC2 Fleet plugin for on-demand Windows agents
#   - Only create this if you actually have Windows/.NET builds
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_instance" "jenkins_windows_agent" {
  ami                         = data.aws_ami.windows_2022.id
  instance_type               = var.jenkins_agent_instance_type
  subnet_id                   = var.private_subnet_ids[0]
  vpc_security_group_ids      = [var.jenkins_windows_agent_sg_id]
  iam_instance_profile        = var.jenkins_agent_profile
  key_name                    = var.key_name
  associate_public_ip_address = false
  get_password_data           = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 60  # Windows needs more base disk than Linux
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/../../scripts/jenkins_windows_agent_userdata.ps1", {
    jenkins_master_private_ip = aws_instance.jenkins_master.private_ip
    aws_region                = var.aws_region
    environment               = var.environment
  })

  depends_on = [aws_instance.jenkins_master]

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-windows-agent-1"
    Role = "jenkins-agent-windows"
  })
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal ALB → changed to internet-facing for POC (no VPN required)
#
# POC:        internal = false  ← current  (reachable from your laptop directly)
# Production: internal = true   ← change this and set up VPN or AWS Client VPN
#
# SECURITY NOTE FOR POC:
#   With internal=false the ALB gets a public DNS name.
#   The ALB security group limits port 80 to corporate_ip_ranges in terraform.tfvars.
#   Set corporate_ip_ranges to your specific home/office IP for better security.
#   Example: ["203.0.113.5/32"] — find your IP at https://checkip.amazonaws.com
# ─────────────────────────────────────────────────────────────────────────────

resource "aws_lb" "jenkins" {
  name               = "${local.name_prefix}-jenkins-alb"
  internal           = false  # POC: public. Change to true when VPN is in place.
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]

  # POC uses public subnets for internet-facing ALB
  # Production with internal=true: use private_subnet_ids instead
  subnets = var.public_subnet_ids

  enable_deletion_protection = false  # POC: allow easy destroy. Set true in production.
  enable_http2               = true

  # Access logs disabled for POC — enable in production after adding bucket policy
  # See fix-alb-s3-permission.md for the S3 bucket policy required
  access_logs {
    bucket  = var.backups_bucket_name
    prefix  = "alb-access-logs"
    enabled = false
  }

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-alb"
  })
}

resource "aws_lb_target_group" "jenkins" {
  name        = "${local.name_prefix}-jenkins-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    path                = "/login"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
  }

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-tg"
  })
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins_master.id
  port             = 8080
}

resource "aws_lb_listener" "jenkins_http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }

  tags = var.common_tags
}

# HTTPS LISTENER (for future use — uncomment when ACM cert is ready)
# resource "aws_lb_listener" "jenkins_https" {
#   load_balancer_arn = aws_lb.jenkins.arn
#   port              = 443
#   protocol          = "HTTPS"
#   ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
#   certificate_arn   = var.acm_certificate_arn
#   default_action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.jenkins.arn
#   }
# }