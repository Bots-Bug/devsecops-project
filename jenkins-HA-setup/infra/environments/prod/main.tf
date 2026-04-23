terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "devops-team"
    CostCenter  = "platform-engineering"
  }
}

data "aws_caller_identity" "current" {}

# ─── Module: Network ──────────────────────────────────────────────────────

module "network" {
  source = "../../../modules/network"

  project              = var.project
  environment          = var.environment
  aws_region           = var.aws_region
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  common_tags          = local.common_tags
}

# ─── Module: Security ─────────────────────────────────────────────────────

module "security" {
  source = "../../../modules/security"

  project             = var.project
  environment         = var.environment
  vpc_id              = module.network.vpc_id
  vpc_cidr            = module.network.vpc_cidr
  aws_region          = var.aws_region    # required for KMS key policy
  corporate_ip_ranges = var.corporate_ip_ranges
  common_tags         = local.common_tags
}

# ─── Module: Jenkins (IAM, S3, Secrets, Backup) ───────────────────────────

module "jenkins" {
  source = "../../../modules/jenkins"

  project             = var.project
  environment         = var.environment
  kms_key_arn         = module.security.kms_key_arn
  aws_region          = var.aws_region
  aws_account_id      = data.aws_caller_identity.current.account_id
  ldap_server_url     = var.ldap_server_url
  jenkins_admin_email = var.jenkins_admin_email
  common_tags         = local.common_tags
}

# ─── Module: Compute (EC2, EFS, ALB) ─────────────────────────────────────

module "compute" {
  source = "../../../modules/compute"

  project                     = var.project
  environment                 = var.environment
  aws_region                  = var.aws_region
  vpc_id                      = module.network.vpc_id
  vpc_cidr                    = module.network.vpc_cidr
  public_subnet_ids           = module.network.public_subnet_ids
  private_subnet_ids          = module.network.private_subnet_ids
  kms_key_arn                 = module.security.kms_key_arn
  kms_key_id                  = module.security.kms_key_id
  bastion_sg_id               = module.security.bastion_sg_id
  alb_sg_id                   = module.security.alb_sg_id
  jenkins_master_sg_id        = module.security.jenkins_master_sg_id
  jenkins_linux_agent_sg_id   = module.security.jenkins_linux_agent_sg_id
  jenkins_windows_agent_sg_id = module.security.jenkins_windows_agent_sg_id
  efs_sg_id                   = module.security.efs_sg_id
  jenkins_master_profile      = module.jenkins.jenkins_master_profile_name
  jenkins_agent_profile       = module.jenkins.jenkins_agent_profile_name
  backups_bucket_name         = module.jenkins.backups_bucket_name
  backup_plan_id              = module.jenkins.backup_plan_id
  backup_role_arn             = module.jenkins.backup_role_arn
  backup_vault_name           = module.jenkins.backup_vault_name
  master_log_group_name       = module.jenkins.master_log_group_name
  acm_certificate_arn         = var.acm_certificate_arn
  key_name                    = var.key_name
  jenkins_master_instance_type = var.jenkins_master_instance_type
  jenkins_agent_instance_type  = var.jenkins_agent_instance_type
  linux_agent_count            = var.linux_agent_count
  common_tags                  = local.common_tags
}