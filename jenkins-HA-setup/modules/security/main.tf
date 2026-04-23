locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─── KMS Key ───────────────────────────────────────────────────────────────
# Encrypts: EFS, S3, EBS, Secrets Manager, CloudWatch Logs
# POC: deletion_window_in_days = 7
# Production: set to 30

resource "aws_kms_key" "jenkins" {
  description             = "KMS key for Jenkins ${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.common_tags, {
    Name    = "${local.name_prefix}-kms-key"
    Purpose = "jenkins-encryption"
  })
}

resource "aws_kms_alias" "jenkins" {
  name          = "alias/${local.name_prefix}-jenkins"
  target_key_id = aws_kms_key.jenkins.key_id
}

# ─── Security Group: Bastion ───────────────────────────────────────────────

resource "aws_security_group" "bastion" {
  name        = "${local.name_prefix}-bastion-sg"
  description = "Bastion host SSH from corporate IP only"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-bastion-sg" })
}

resource "aws_security_group_rule" "bastion_ssh_inbound" {
  count             = length(var.corporate_ip_ranges)
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.corporate_ip_ranges[count.index]]
  security_group_id = aws_security_group.bastion.id
  description       = "SSH from ${var.corporate_ip_ranges[count.index]}"
}

resource "aws_security_group_rule" "bastion_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.bastion.id
  description       = "All outbound"
}

# ─── Security Group: ALB ──────────────────────────────────────────────────
# POC: port 80, internet-facing ALB
# Production: port 443, internal ALB, VPN CIDR only

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Jenkins ALB  HTTP inbound"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-alb-sg" })
}

resource "aws_security_group_rule" "alb_http_inbound" {
  count             = length(var.corporate_ip_ranges)
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.corporate_ip_ranges[count.index]]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${var.corporate_ip_ranges[count.index]}"
}

resource "aws_security_group_rule" "alb_http_vpc" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from within VPC"
}

resource "aws_security_group_rule" "alb_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "All outbound"
}

# ─── Security Group: Jenkins Master ───────────────────────────────────────

resource "aws_security_group" "jenkins_master" {
  name        = "${local.name_prefix}-jenkins-master-sg"
  description = "Jenkins master  private access only"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-jenkins-master-sg" })
}

resource "aws_security_group_rule" "master_http_from_alb" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.jenkins_master.id
  description              = "Jenkins UI from ALB only"
}

resource "aws_security_group_rule" "master_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.jenkins_master.id
  description              = "SSH from bastion"
}

resource "aws_security_group_rule" "master_jnlp_from_linux_agent" {
  type                     = "ingress"
  from_port                = 50000
  to_port                  = 50000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.jenkins_linux_agent.id
  security_group_id        = aws_security_group.jenkins_master.id
  description              = "JNLP from Linux agents"
}

resource "aws_security_group_rule" "master_jnlp_from_windows_agent" {
  type                     = "ingress"
  from_port                = 50000
  to_port                  = 50000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.jenkins_windows_agent.id
  security_group_id        = aws_security_group.jenkins_master.id
  description              = "JNLP from Windows agent"
}

resource "aws_security_group_rule" "master_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.jenkins_master.id
  description       = "All outbound"
}

# ─── Security Group: Linux Agents ─────────────────────────────────────────

resource "aws_security_group" "jenkins_linux_agent" {
  name        = "${local.name_prefix}-linux-agent-sg"
  description = "Jenkins Linux agents"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-linux-agent-sg" })
}

resource "aws_security_group_rule" "linux_agent_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.jenkins_linux_agent.id
  description              = "SSH from bastion"
}

resource "aws_security_group_rule" "linux_agent_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.jenkins_linux_agent.id
  description       = "All outbound"
}

# ─── Security Group: Windows Agent ────────────────────────────────────────

resource "aws_security_group" "jenkins_windows_agent" {
  name        = "${local.name_prefix}-windows-agent-sg"
  description = "Jenkins Windows agent"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-windows-agent-sg" })
}

resource "aws_security_group_rule" "windows_agent_rdp_from_bastion" {
  type                     = "ingress"
  from_port                = 3389
  to_port                  = 3389
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.bastion.id
  security_group_id        = aws_security_group.jenkins_windows_agent.id
  description              = "RDP from bastion only"
}

resource "aws_security_group_rule" "windows_agent_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.jenkins_windows_agent.id
  description       = "All outbound"
}

# ─── Security Group: EFS ──────────────────────────────────────────────────

resource "aws_security_group" "efs" {
  name        = "${local.name_prefix}-efs-sg"
  description = "EFS mount targets - NFS from Jenkins master only"
  vpc_id      = var.vpc_id
  tags = merge(var.common_tags, { Name = "${local.name_prefix}-efs-sg" })
}

resource "aws_security_group_rule" "efs_nfs_from_master" {
  type                     = "ingress"
  from_port                = 2049
  to_port                  = 2049
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.jenkins_master.id
  security_group_id        = aws_security_group.efs.id
  description              = "NFS from Jenkins master"
}

resource "aws_security_group_rule" "efs_outbound" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = [var.vpc_cidr]
  security_group_id = aws_security_group.efs.id
  description       = "Response traffic within VPC"
}

# ─── Data Sources ─────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}