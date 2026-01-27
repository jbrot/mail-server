output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.mail_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the mail server"
  value       = aws_instance.mail_server.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the mail server"
  value       = "ssh root@${aws_instance.mail_server.public_ip}"
}

output "data_volume_id" {
  description = "EBS volume ID for mail data"
  value       = aws_ebs_volume.data.id
}

output "nixos_ami_id" {
  description = "NixOS AMI ID used for the instance"
  value       = data.aws_ami.nixos.id
}

output "private_key" {
  description = "Private SSH key for accessing the instance"
  value       = tls_private_key.mail_server.private_key_openssh
  sensitive   = true
}
