# Default mail server configuration for aarch64 (test/example)
# Copy to config/production/ and modify for your production deployment
{
  # Mail domain settings
  domain = "test.local";
  hostname = "mail.test.local";

  # Mail users are loaded from the accounts/ directory.
  # Create accounts with: ./scripts/create-account.sh

  # Mail aliases (alias = target username)
  aliases = {
    "postmaster" = "alice";
    "abuse" = "alice";
    "admin" = "alice";
  };

  # DKIM signing configuration
  dkim = {
    # Enable DKIM signing for outbound mail (default: true)
    enable = true;
    # DKIM selector - used in DNS record name: <selector>._domainkey.<domain>
    # Use a dated selector (e.g., "mail2026") to allow key rotation
    selector = "mail";
  };

  # SPF - structured options build the record automatically
  # Defaults: mx enabled, hard fail qualifier
  spf = {
    enable = true;
    mechanisms.mx = true;
    qualifier = "-all";
  };

  # DMARC - structured options
  # Default: quarantine policy
  dmarc = {
    enable = true;
    policy = "quarantine";
  };

  # Mozilla Autoconfig for email client auto-discovery
  autoconfig.enable = false;

  # ACME (Let's Encrypt) certificate settings
  acme = {
    email = "admin@example.com";  # Contact email for certificate notifications
    staging = true;  # Use staging server for testing (avoids rate limits)
  };

  # Target architecture
  architecture = "aarch64-linux";

  # Monitoring alerts (Monit)
  # Username for system alerts (disk space, memory, etc.) - domain is added automatically
  # Set to "postmaster" to send alerts to postmaster@<domain>
  # Default: disabled (no alert emails)
  # Note: Enabling alerts also enables the local submission port for system-generated mail
  alertEmail = "postmaster";

  # AWS settings (used by Terraform via generated tfvars)
  # Using Graviton instances for better price/performance
  aws = {
    # Project name (used for AWS resource naming and tagging)
    project = "email-server";

    region = "us-east-1";
    instanceType = "t4g.small";
    rootVolumeSize = 8;
    dataVolumeSize = 50;
    swapSize = 1;  # GB

    # CIDR block for SSH access ("auto" = current IP, or e.g., "1.2.3.4/32")
    adminCidr = "auto";

    # Route53 DNS settings
    route53 = {
      # Existing hosted zone ID (leave empty to create a new zone for the domain)
      zoneId = "";
      # Whether to create MX record (set false during migration, true when ready to go live)
      createMX = false;
      # SRV records for email auto-discovery (RFC 6186)
      createSRV = false;
    };

    # Elastic IP allocation ID for static IP / reverse DNS (optional)
    # Get your allocation ID with: aws ec2 describe-addresses
    # Set PTR record with: aws ec2 modify-address-attribute --allocation-id <id> --domain-name <hostname>
    # eipAllocationId = "eipalloc-0123456789abcdef0";

    # AMI override (optional - pin to prevent instance recreation when upstream AMI changes)
    # Leave blank for initial deploy, then fill in with your instance's AMI ID afterward.
    # Get your AMI ID with: aws ec2 describe-instances --query 'Reservations[].Instances[].ImageId'
    # amiId = "ami-0123456789abcdef0";

    # Availability zone (optional - pin to prevent data volume recreation on instance changes)
    # Leave blank for initial deploy, then fill in with your instance's AZ afterward.
    # Get your AZ with: aws ec2 describe-instances --query 'Reservations[].Instances[].Placement.AvailabilityZone'
    # availabilityZone = "us-east-1a";

    # Automated EBS snapshots via AWS Data Lifecycle Manager
    # Cost: ~$0.15-0.25/month for a small mail server
    backup = {
      enable = true;
      time = "03:00";  # UTC, 24h format
      daily.retain = 7;   # Keep 7 daily snapshots
      weekly.retain = 4;  # Keep 4 weekly snapshots (Sundays)
    };
  };

  # Container resource limits (memory in MB)
  # Defaults are tuned for t4g.micro (1GB RAM) or t4g.nano (512MB + 1GB swap)
  # Increase for larger instances or heavier workloads
  resources = {
    opensmtpd.memory = 192;
    dovecot.memory = 192;
    rspamd.memory = 384;
    redis.memory = 192;
  };
}
