terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "email-server/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# Data source for latest NixOS AMI (community)
data "aws_ami" "nixos" {
  count       = var.nixos_ami == "" ? 1 : 0
  most_recent = true
  owners      = ["427812963091"] # NixOS community AMI owner

  filter {
    name   = "name"
    values = ["nixos/24.05*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.nixos_ami != "" ? var.nixos_ami : data.aws_ami.nixos[0].id
}

# VPC - using default VPC for simplicity
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security Group for mail server
resource "aws_security_group" "mail_server" {
  name        = "${var.project}-mail-server"
  description = "Security group for mail server"
  vpc_id      = data.aws_vpc.default.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  # HTTPS (for Netdata UI, optional)
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Netdata (restrict to your IP in production)
  ingress {
    description = "Netdata UI"
    from_port   = 19999
    to_port     = 19999
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict in production
  }

  # All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project}-mail-server"
  })
}

# IAM role for EC2 instance
resource "aws_iam_role" "mail_server" {
  name = "${var.project}-mail-server"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM policy for ECR access
resource "aws_iam_role_policy" "ecr_access" {
  name = "ecr-access"
  role = aws_iam_role.mail_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM policy for Route53 (for DNS-01 ACME challenges, optional)
resource "aws_iam_role_policy" "route53_access" {
  name = "route53-access"
  role = aws_iam_role.mail_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "route53:GetChange",
          "route53:ListHostedZones"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets"
        ]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
      }
    ]
  })
}

# IAM instance profile
resource "aws_iam_instance_profile" "mail_server" {
  name = "${var.project}-mail-server"
  role = aws_iam_role.mail_server.name
}

# Elastic IP for stable addressing
resource "aws_eip" "mail_server" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project}-mail-server"
  })
}

# EBS volume for mail data
resource "aws_ebs_volume" "data" {
  availability_zone = "${var.aws_region}a"
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = merge(local.common_tags, {
    Name = "${var.project}-data"
  })
}

# EC2 Instance
resource "aws_instance" "mail_server" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.mail_server.id]
  iam_instance_profile   = aws_iam_instance_profile.mail_server.name
  availability_zone      = "${var.aws_region}a"

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # User data to set up initial configuration
  user_data = <<-EOF
    #cloud-config
    write_files:
      - path: /etc/nixos/host-id
        content: |
          ${substr(sha256(var.mail_hostname), 0, 8)}
    runcmd:
      - echo "NixOS mail server initialized"
  EOF

  tags = merge(local.common_tags, {
    Name = "${var.project}-mail-server"
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# Attach EBS volume to instance
resource "aws_volume_attachment" "data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mail_server.id
}

# Associate Elastic IP with instance
resource "aws_eip_association" "mail_server" {
  instance_id   = aws_instance.mail_server.id
  allocation_id = aws_eip.mail_server.id
}

# Route53 DNS Records

# A record for mail server
resource "aws_route53_record" "mail_a" {
  zone_id = var.route53_zone_id
  name    = var.mail_hostname
  type    = "A"
  ttl     = 300
  records = [aws_eip.mail_server.public_ip]
}

# MX record
resource "aws_route53_record" "mx" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "MX"
  ttl     = 300
  records = ["10 ${var.mail_hostname}."]
}

# SPF record
resource "aws_route53_record" "spf" {
  zone_id = var.route53_zone_id
  name    = var.domain
  type    = "TXT"
  ttl     = 300
  records = ["v=spf1 mx -all"]
}

# DMARC record
resource "aws_route53_record" "dmarc" {
  zone_id = var.route53_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=quarantine; rua=mailto:postmaster@${var.domain}"]
}

# Note: DKIM record should be added manually after Rspamd generates the key
# resource "aws_route53_record" "dkim" {
#   zone_id = var.route53_zone_id
#   name    = "mail._domainkey.${var.domain}"
#   type    = "TXT"
#   ttl     = 300
#   records = ["v=DKIM1; k=rsa; p=YOUR_PUBLIC_KEY_HERE"]
# }
