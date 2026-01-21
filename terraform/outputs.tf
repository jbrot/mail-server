# Instance outputs
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.mail_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the mail server"
  value       = aws_eip.mail_server.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the mail server"
  value       = aws_instance.mail_server.private_ip
}

# ECR outputs
output "ecr_opensmtpd_url" {
  description = "ECR repository URL for OpenSMTPd"
  value       = aws_ecr_repository.opensmtpd.repository_url
}

output "ecr_dovecot_url" {
  description = "ECR repository URL for Dovecot"
  value       = aws_ecr_repository.dovecot.repository_url
}

output "ecr_rspamd_url" {
  description = "ECR repository URL for Rspamd"
  value       = aws_ecr_repository.rspamd.repository_url
}

output "ecr_registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = aws_ecr_repository.opensmtpd.registry_id
}

# DNS outputs
output "mail_server_fqdn" {
  description = "Fully qualified domain name of the mail server"
  value       = aws_route53_record.mail_a.fqdn
}

output "mx_record" {
  description = "MX record value"
  value       = aws_route53_record.mx.records
}

# Connection info
output "ssh_command" {
  description = "SSH command to connect to the mail server"
  value       = "ssh root@${aws_eip.mail_server.public_ip}"
}

# Data volume
output "data_volume_id" {
  description = "EBS volume ID for mail data"
  value       = aws_ebs_volume.data.id
}
