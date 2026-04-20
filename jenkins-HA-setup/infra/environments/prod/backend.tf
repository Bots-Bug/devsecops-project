terraform {
  backend "s3" {
    bucket         = "jenkins-shared-terraform-state-433214487294"
    key            = "jenkins/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "jenkins-shared-terraform-lock"
    encrypt        = true
  }
}