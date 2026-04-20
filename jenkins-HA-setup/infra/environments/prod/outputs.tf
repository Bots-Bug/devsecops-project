output "vpc_id" {
  value = module.network.vpc_id
}

output "bastion_public_ip" {
  description = "SSH to this IP to access bastion host"
  value       = module.compute.bastion_public_ip
}

output "jenkins_master_private_ip" {
  description = "Jenkins master IP (accessible only via VPN or bastion)"
  value       = module.compute.jenkins_master_private_ip
}

output "jenkins_url" {
  description = "Jenkins internal URL via ALB (requires VPN)"
  value       = "https://${module.compute.alb_dns_name}"
}

output "efs_id" {
  description = "EFS filesystem ID for Jenkins home"
  value       = module.compute.efs_id
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