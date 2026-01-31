variable "project" {
  description = "Project name for resource naming and tagging"
  type        = string
  default     = "email-server"
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}

variable "architecture" {
  description = "CPU architecture (x86_64-linux or aarch64-linux)"
  type        = string
  default     = "x86_64-linux"

  validation {
    condition     = contains(["x86_64-linux", "aarch64-linux"], var.architecture)
    error_message = "Architecture must be either x86_64-linux or aarch64-linux."
  }
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GB"
  type        = number
  default     = 8
}

variable "data_volume_size" {
  description = "Size of the EBS data volume in GB"
  type        = number
  default     = 50
}

variable "nixos_version" {
  description = "NixOS version for AMI selection (e.g., 24.05)"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR block for SSH access ('auto' = detect current IP, or e.g., '1.2.3.4/32')"
  type        = string
  default     = "auto"
}

variable "domain" {
  description = "Primary email domain (e.g., example.com)"
  type        = string
}

variable "hostname" {
  description = "Mail server hostname (e.g., mail.example.com)"
  type        = string
}

variable "route53_zone_id" {
  description = "Existing Route53 hosted zone ID (empty to create new zone)"
  type        = string
  default     = ""
}

variable "route53_create_mx" {
  description = "Whether to create MX record (set false during migration)"
  type        = bool
  default     = false
}

variable "spf_record" {
  description = "SPF record value (empty string = disabled)"
  type        = string
  default     = ""
}

variable "dmarc_record" {
  description = "DMARC record value (empty string = disabled)"
  type        = string
  default     = ""
}

# Backup settings
variable "backup_enabled" {
  description = "Enable automated EBS snapshots via Data Lifecycle Manager"
  type        = bool
  default     = true
}

variable "backup_daily_retain" {
  description = "Number of daily snapshots to retain"
  type        = number
  default     = 7
}

variable "backup_weekly_retain" {
  description = "Number of weekly snapshots to retain"
  type        = number
  default     = 4
}

variable "backup_time" {
  description = "Time to run daily backups (UTC, 24h format HH:MM)"
  type        = string
  default     = "03:00"
}
