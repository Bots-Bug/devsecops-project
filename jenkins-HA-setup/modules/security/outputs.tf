output "kms_key_arn"                { value = aws_kms_key.jenkins.arn }
output "kms_key_id"                 { value = aws_kms_key.jenkins.key_id }
output "bastion_sg_id"              { value = aws_security_group.bastion.id }
output "alb_sg_id"                  { value = aws_security_group.alb.id }
output "jenkins_master_sg_id"       { value = aws_security_group.jenkins_master.id }
output "jenkins_linux_agent_sg_id"  { value = aws_security_group.jenkins_linux_agent.id }
output "jenkins_windows_agent_sg_id" { value = aws_security_group.jenkins_windows_agent.id }
output "efs_sg_id"                  { value = aws_security_group.efs.id }