variable "project"           { type = string }
variable "environment"       { type = string }
variable "kms_key_arn"       { type = string }
variable "aws_region"        { type = string }
variable "aws_account_id"    { type = string }

variable "ldap_server_url" {
  description = "LDAP server URL for Jenkins authentication"
  type        = string
  default     = "ldap://your-ad-server.internal.example.com:389"
}

variable "jenkins_admin_email" {
  description = "Jenkins admin email for notifications"
  type        = string
  default     = "jenkins-admin@example.com"
}

variable "common_tags" {
  type    = map(string)
  default = {}
}