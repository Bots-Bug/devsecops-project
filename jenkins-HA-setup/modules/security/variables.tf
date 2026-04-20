variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }

variable "corporate_ip_ranges" {
  description = "CIDR ranges for corporate network / VPN client range"
  type        = list(string)
  default     = ["10.100.0.0/16"]  # Replace with your VPN client CIDR
}

variable "common_tags" {
  type    = map(string)
  default = {}
}