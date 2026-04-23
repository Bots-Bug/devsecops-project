locals {
  name_prefix = "${var.project}-${var.environment}"
}

# ─── IAM Role: Jenkins Master ─────────────────────────────────────────────

resource "aws_iam_role" "jenkins_master" {
  name = "${local.name_prefix}-jenkins-master-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-master-role"
  })
}

resource "aws_iam_instance_profile" "jenkins_master" {
  name = "${local.name_prefix}-jenkins-master-profile"
  role = aws_iam_role.jenkins_master.name
}

# S3 access for artifacts and backups
resource "aws_iam_role_policy" "jenkins_master_s3" {
  name = "${local.name_prefix}-jenkins-master-s3-policy"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "JenkinsBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = [
          aws_s3_bucket.jenkins_artifacts.arn,
          "${aws_s3_bucket.jenkins_artifacts.arn}/*",
          aws_s3_bucket.jenkins_backups.arn,
          "${aws_s3_bucket.jenkins_backups.arn}/*"
        ]
      }
    ]
  })
}

# Secrets Manager access - read only for credentials
resource "aws_iam_role_policy" "jenkins_master_secrets" {
  name = "${local.name_prefix}-jenkins-master-secrets-policy"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadJenkinsSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecrets"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.aws_account_id}:secret:${local.name_prefix}/*"
      },
      {
        Sid    = "KMSForSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# SSM for SSH-less access and parameter store
resource "aws_iam_role_policy_attachment" "jenkins_master_ssm" {
  role       = aws_iam_role.jenkins_master.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch agent permissions
resource "aws_iam_role_policy_attachment" "jenkins_master_cloudwatch" {
  role       = aws_iam_role.jenkins_master.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ECR read access for building Docker images during pipelines (optional)
resource "aws_iam_role_policy" "jenkins_master_ecr" {
  name = "${local.name_prefix}-jenkins-master-ecr-policy"
  role = aws_iam_role.jenkins_master.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ECRReadAccess"
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ]
      Resource = "*"
    }]
  })
}

# ─── IAM Role: Jenkins Agents ─────────────────────────────────────────────

resource "aws_iam_role" "jenkins_agent" {
  name = "${local.name_prefix}-jenkins-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-agent-role"
  })
}

resource "aws_iam_instance_profile" "jenkins_agent" {
  name = "${local.name_prefix}-jenkins-agent-profile"
  role = aws_iam_role.jenkins_agent.name
}

resource "aws_iam_role_policy_attachment" "jenkins_agent_ssm" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "jenkins_agent_cloudwatch" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy" "jenkins_agent_s3_artifacts" {
  name = "${local.name_prefix}-jenkins-agent-s3-policy"
  role = aws_iam_role.jenkins_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AgentArtifactAccess"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.jenkins_artifacts.arn,
        "${aws_s3_bucket.jenkins_artifacts.arn}/*"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_agent_ecr" {
  name = "${local.name_prefix}-jenkins-agent-ecr-policy"
  role = aws_iam_role.jenkins_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPushPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
        ]
        Resource = "arn:aws:ecr:${var.aws_region}:${var.aws_account_id}:repository/*"
      }
    ]
  })
}

# ─── S3 Bucket: Jenkins Artifacts ─────────────────────────────────────────

resource "aws_s3_bucket" "jenkins_artifacts" {
  bucket = "${local.name_prefix}-jenkins-artifacts-${var.aws_account_id}"

  tags = merge(var.common_tags, {
    Name    = "${local.name_prefix}-jenkins-artifacts"
    Purpose = "build-artifacts"
  })
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.jenkins_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.jenkins_artifacts.id
  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

# ─── S3 Bucket: Jenkins Backups ───────────────────────────────────────────

resource "aws_s3_bucket" "jenkins_backups" {
  bucket = "${local.name_prefix}-jenkins-backups-${var.aws_account_id}"

  tags = merge(var.common_tags, {
    Name    = "${local.name_prefix}-jenkins-backups"
    Purpose = "jenkins-home-backups"
  })
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.jenkins_backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.jenkins_backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.jenkins_backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.jenkins_backups.id
  rule {
    id     = "backup-retention"
    status = "Enabled"
    filter {}
    # Keep recent backups on standard storage for 30 days
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    # Move to Glacier after 90 days (for compliance/DR)
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    # Expire after 1 year
    expiration { days = 365 }
  }
}

# ─── Secrets Manager: Jenkins Secrets ─────────────────────────────────────

# Jenkins admin credentials - populated manually or via pipeline
resource "aws_secretsmanager_secret" "jenkins_admin" {
  name                    = "${local.name_prefix}/jenkins/admin-credentials"
  description             = "Jenkins admin username and password"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7

  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "jenkins_admin" {
  secret_id = aws_secretsmanager_secret.jenkins_admin.id
  secret_string = jsonencode({
    username = "jenkins-admin"
    password = "admin@123"  # Replace before first apply
  })

  lifecycle {
    ignore_changes = [secret_string]  # Don't overwrite after manual rotation
  }
}

# LDAP/AD bind credentials
resource "aws_secretsmanager_secret" "ldap_credentials" {
  name                    = "${local.name_prefix}/jenkins/ldap-bind-credentials"
  description             = "LDAP bind DN and password for Jenkins auth"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7

  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "ldap_credentials" {
  secret_id = aws_secretsmanager_secret.ldap_credentials.id
  secret_string = jsonencode({
    bind_dn       = "dummy"
    bind_password = "dummy"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# GitHub/GitLab integration token
resource "aws_secretsmanager_secret" "git_credentials" {
  name                    = "${local.name_prefix}/jenkins/git-credentials"
  description             = "Git access token for Jenkins pipeline checkouts"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7

  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "git_credentials" {
  secret_id = aws_secretsmanager_secret.git_credentials.id
  secret_string = jsonencode({
    username = "jenkins-git-bot"
    token    = "dummy"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ─── AWS Backup: EFS Jenkins Home ─────────────────────────────────────────

resource "aws_backup_vault" "jenkins" {
  name        = "${local.name_prefix}-jenkins-backup-vault"
  kms_key_arn = var.kms_key_arn

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-backup-vault"
  })
}

resource "aws_backup_plan" "jenkins_efs" {
  name = "${local.name_prefix}-jenkins-efs-backup-plan"

  rule {
    rule_name         = "daily-backups"
    target_vault_name = aws_backup_vault.jenkins.name
    schedule          = "cron(0 3 * * ? *)"  # 3 AM daily
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = 30  # Keep 30 days of daily backups
    }
  }

  rule {
    rule_name         = "weekly-backups"
    target_vault_name = aws_backup_vault.jenkins.name
    schedule          = "cron(0 4 ? * SUN *)"  # 4 AM every Sunday
    start_window      = 60
    completion_window = 360

    lifecycle {
      cold_storage_after = 30   # Move to cold storage after 30 days
      delete_after       = 365  # Keep weekly backups for 1 year
    }
  }

  tags = var.common_tags
}

resource "aws_iam_role" "backup" {
  name = "${local.name_prefix}-aws-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# ─── SNS Topic for Alerts ─────────────────────────────────────────────────

resource "aws_sns_topic" "jenkins_alerts" {
  name              = "${local.name_prefix}-jenkins-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-jenkins-alerts"
  })
}

resource "aws_sns_topic_subscription" "jenkins_alerts_email" {
  topic_arn = aws_sns_topic.jenkins_alerts.arn
  protocol  = "email"
  endpoint  = var.jenkins_admin_email
}

# ─── CloudWatch Log Groups ─────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "jenkins_master" {
  name              = "/jenkins/${local.name_prefix}/master"
  retention_in_days = 90
  kms_key_id        = var.kms_key_arn

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "jenkins_agents" {
  name              = "/jenkins/${local.name_prefix}/agents"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = var.common_tags
}

# ─── IAM Role: Bastion ────────────────────────────────────────────────────
# Bastion runs Ansible. Ansible dynamic inventory needs ec2:Describe* to
# discover instances by tag. Read-only, no write permissions.

resource "aws_iam_role" "bastion" {
  name = "${local.name_prefix}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${local.name_prefix}-bastion-role"
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name_prefix}-bastion-profile"
  role = aws_iam_role.bastion.name
}

resource "aws_iam_role_policy" "bastion_ec2_read" {
  name = "${local.name_prefix}-bastion-ec2-read"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "EC2ReadForAnsibleInventory"
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "ec2:DescribeRegions",
        "ec2:DescribeAvailabilityZones"
      ]
      Resource = "*"
    }]
  })
}

# SSM for passwordless access to bastion (optional but useful)
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}