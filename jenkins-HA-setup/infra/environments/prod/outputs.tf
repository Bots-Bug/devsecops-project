output "vpc_id" {
  value = module.network.vpc_id
}

output "bastion_public_ip" {
  description = "SSH: ssh ec2-user@IP -i ~/.ssh/jenkins-prod-keypair.pem"
  value       = module.compute.bastion_public_ip
}

output "jenkins_master_private_ip" {
  value = module.compute.jenkins_master_private_ip
}

output "jenkins_master_id" {
  description = "For SSM: aws ssm start-session --target ID"
  value       = module.compute.jenkins_master_id
}

output "jenkins_url" {
  description = "Open in browser (HTTP, no VPN needed for POC)"
  value       = "http://${module.compute.alb_dns_name}/"
}

output "alb_dns_name" {
  value = module.compute.alb_dns_name
}

output "efs_id" {
  value = module.compute.efs_id
}

output "artifacts_bucket" {
  value = module.jenkins.artifacts_bucket_name
}

output "backups_bucket" {
  value = module.jenkins.backups_bucket_name
}

output "linux_agent_ips" {
  value = module.compute.linux_agent_private_ips
}

output "windows_agent_ip" {
  value = module.compute.windows_agent_private_ip
}