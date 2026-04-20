variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name - used in resource naming"
  type        = string
  default     = "jenkins"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "shared"
}