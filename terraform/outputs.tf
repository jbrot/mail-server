output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.mail_server.id
}

output "instance_public_ip" {
  description = "Public IP address of the mail server"
  value       = local.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the mail server"
  value       = "ssh root@${local.public_ip}"
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

output "dns_zone_id" {
  description = "Route53 hosted zone ID"
  value       = local.zone_id
}

output "dns_zone_nameservers" {
  description = "Nameservers for the hosted zone (update at your registrar if zone was created)"
  value       = var.route53_zone_id == "" ? aws_route53_zone.mail_domain[0].name_servers : ["Using existing zone"]
}

output "dns_a_record" {
  description = "A record created for mail server"
  value       = "${var.hostname} -> ${local.public_ip}"
}

output "dns_mx_record" {
  description = "MX record status"
  value       = var.route53_create_mx ? "${var.domain} MX 10 ${var.hostname}." : "Not created (route53_create_mx = false)"
}
