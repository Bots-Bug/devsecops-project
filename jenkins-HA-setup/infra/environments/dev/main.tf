terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "acme-corp-terraform-state-prod"
    key            = "jenkins/prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "acme-corp-terraform-locks"
    kms_key_id     = "arn:aws:kms:us-east-1:123456789:key/your-kms-key-id"
  }
}