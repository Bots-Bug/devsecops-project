variable "project"                    { type = string }
variable "environment"                { type = string }
variable "aws_region"                 { type = string }
variable "vpc_id"                     { type = string }
variable "vpc_cidr"                   { type = string }
variable "public_subnet_ids"          { type = list(string) }
variable "private_subnet_ids"         { type = list(string) }
variable "kms_key_arn"                { type = string }
variable "kms_key_id"                 { type = string }
variable "bastion_sg_id"              { type = string }
variable "alb_sg_id"                  { type = string }
variable "jenkins_master_sg_id"       { type = string }
variable "jenkins_linux_agent_sg_id"  { type = string }
variable "jenkins_windows_agent_sg_id" { type = string }
variable "efs_sg_id"                  { type = string }
variable "jenkins_master_profile"     { type = string }
variable "jenkins_agent_profile"      { type = string }
variable "backups_bucket_name"        { type = string }
variable "backup_plan_id"             { type = string }
variable "backup_role_arn"            { type = string }
variable "backup_vault_name"          { type = string }
variable "master_log_group_name"      { type = string }
variable "key_name"                   { type = string }

variable "acm_certificate_arn" {
  type    = string
  default = ""   # <── empty = HTTP mode, no cert needed
}

variable "jenkins_master_instance_type" {
  type    = string
  default = "m5.xlarge"
}

variable "jenkins_agent_instance_type" {
  type    = string
  default = "t3.large"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "jenkins_master_volume_size" {
  type    = number
  default = 30
}

variable "linux_agent_count" {
  type    = number
  default = 2
}

variable "common_tags" {
  type    = map(string)
  default = {}
}