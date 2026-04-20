variable "aws_region"           { type = string }
variable "project"              { type = string }
variable "environment"          { type = string }
variable "vpc_cidr"             { type = string }
variable "public_subnet_cidrs"  { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "availability_zones"   { type = list(string) }
variable "corporate_ip_ranges"  { type = list(string) }
variable "key_name"             { type = string }
variable "ldap_server_url"      { type = string }
variable "jenkins_admin_email"  { type = string }
variable "linux_agent_count"    { type = number }

variable "jenkins_master_instance_type" { type = string }
variable "jenkins_agent_instance_type"  { type = string }

# ─── ACM is optional now ──────────────────────────────────────────────────
variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for HTTPS. Leave empty to use HTTP (internal ALB only)."
  default     = ""   # <── empty default = HTTP mode
}