terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# Generate SSH key pair
resource "tls_private_key" "mail_server" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "mail_server" {
  key_name   = "${var.project}-mail-server"
  public_key = tls_private_key.mail_server.public_key_openssh

  tags = {
    Name = "${var.project}-mail-server"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

# Data source for latest NixOS AMI (community)
data "aws_ami" "nixos" {
  most_recent = true
  owners      = ["427812963091"] # NixOS community AMI owner

  filter {
    name   = "name"
    values = ["nixos/${var.nixos_version}*-${var.architecture}"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Auto-detect current IP if admin_cidr is "auto"
data "http" "my_ip" {
  count = var.admin_cidr == "auto" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = var.admin_cidr == "auto" ? "${chomp(data.http.my_ip[0].response_body)}/32" : var.admin_cidr
}

# Security Group for mail server
resource "aws_security_group" "mail_server" {
  name        = "${var.project}-mail-server"
  description = "Security group for mail server"

  # SSH (restricted to admin CIDR)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.admin_cidr]
  }

  # SMTP
  ingress {
    description = "SMTP"
    from_port   = 25
    to_port     = 25
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SMTP Submission
  ingress {
    description = "SMTP Submission"
    from_port   = 587
    to_port     = 587
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SMTPS
  ingress {
    description = "SMTPS"
    from_port   = 465
    to_port     = 465
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # IMAPS
  ingress {
    description = "IMAPS"
    from_port   = 993
    to_port     = 993
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP (for ACME challenges)
  ingress {
    description = "HTTP for ACME"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-mail-server"
  }
}

# EC2 Instance
resource "aws_instance" "mail_server" {
  ami                    = data.aws_ami.nixos.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.mail_server.key_name
  vpc_security_group_ids = [aws_security_group.mail_server.id]
  iam_instance_profile   = aws_iam_instance_profile.mail_server.name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project}-mail-server"
  }
}

# EBS volume for mail data (same AZ as instance)
resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.mail_server.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project}-mail-server-data"
  }
}

# Attach EBS volume to instance
resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mail_server.id
}

# Route53 hosted zone - use existing or create new
resource "aws_route53_zone" "mail_domain" {
  count = var.route53_zone_id == "" ? 1 : 0
  name  = var.domain
}

locals {
  # Use existing zone ID if provided, otherwise use created zone
  zone_id = var.route53_zone_id != "" ? var.route53_zone_id : aws_route53_zone.mail_domain[0].zone_id
}

# Route53 A record for mail server hostname
resource "aws_route53_record" "mail_server" {
  zone_id = local.zone_id
  name    = var.hostname
  type    = "A"
  ttl     = 300
  records = [aws_instance.mail_server.public_ip]
}

# MX record pointing to the mail server (optional - for migration)
resource "aws_route53_record" "mx" {
  count   = var.route53_create_mx ? 1 : 0
  zone_id = local.zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 300
  records = ["10 ${var.hostname}."]
}

# SPF TXT record (only created if spf_record is non-empty)
resource "aws_route53_record" "spf" {
  count   = var.spf_record != "" ? 1 : 0
  zone_id = local.zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = 3600
  records = [var.spf_record]
}

# DMARC TXT record (only created if dmarc_record is non-empty)
resource "aws_route53_record" "dmarc" {
  count   = var.dmarc_record != "" ? 1 : 0
  zone_id = local.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 3600
  records = [var.dmarc_record]
}

# IAM role for EC2 instance (DKIM Route53 management)
resource "aws_iam_role" "mail_server" {
  name = "${var.project}-mail-server"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Policy for Route53 record management (DKIM)
# Restricted to: TXT records, _domainkey subdomains, CREATE only (no modify/delete)
resource "aws_iam_role_policy" "route53_dkim" {
  name = "${var.project}-route53-dkim"
  role = aws_iam_role.mail_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListRecords"
        Effect   = "Allow"
        Action   = "route53:ListResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${local.zone_id}"
      },
      {
        Sid      = "CreateDkimRecord"
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${local.zone_id}"
        Condition = {
          "ForAllValues:StringEquals" = {
            "route53:ChangeResourceRecordSetsRecordTypes" = ["TXT"]
            "route53:ChangeResourceRecordSetsActions"     = ["CREATE"]
          }
          "ForAllValues:StringLike" = {
            "route53:ChangeResourceRecordSetsNormalizedRecordNames" = ["*._domainkey.${var.domain}"]
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "mail_server" {
  name = "${var.project}-mail-server"
  role = aws_iam_role.mail_server.name
}
