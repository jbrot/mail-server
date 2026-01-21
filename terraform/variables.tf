# AWS Region
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

# Domain configuration
variable "domain" {
  description = "Primary mail domain (e.g., example.com)"
  type        = string
}

variable "mail_hostname" {
  description = "Hostname for the mail server (e.g., mail.example.com)"
  type        = string
}

# EC2 configuration
variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "key_name" {
  description = "Name of the SSH key pair for EC2 access"
  type        = string
}

# EBS configuration
variable "data_volume_size" {
  description = "Size of the EBS data volume in GB"
  type        = number
  default     = 50
}

# Route53
variable "route53_zone_id" {
  description = "Route53 hosted zone ID for the domain"
  type        = string
}

# Tags
variable "environment" {
  description = "Environment name (e.g., production, staging)"
  type        = string
  default     = "production"
}

variable "project" {
  description = "Project name for tagging"
  type        = string
  default     = "email-server"
}

# NixOS AMI
variable "nixos_ami" {
  description = "NixOS AMI ID (leave empty to use latest community AMI)"
  type        = string
  default     = ""
}
