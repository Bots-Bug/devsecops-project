variable "project"     { type = string }
variable "environment" { type = string }
variable "vpc_id"      { type = string }
variable "vpc_cidr"    { type = string }

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "corporate_ip_ranges" {
  description = "CIDR ranges allowed to access Jenkins ALB and Bastion"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "common_tags" {
  type    = map(string)
  default = {}
}