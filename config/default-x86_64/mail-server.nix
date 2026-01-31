# Default mail server configuration for x86_64 (test/example)
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

  # ACME (Let's Encrypt) certificate settings
  acme = {
    email = "admin@example.com";  # Contact email for certificate notifications
    staging = true;  # Use staging server for testing (avoids rate limits)
  };

  # Target architecture
  architecture = "x86_64-linux";

  # Monitoring alerts (Monit)
  # Username for system alerts (disk space, memory, etc.) - domain is added automatically
  # Set to "postmaster" to send alerts to postmaster@<domain>
  # Default: disabled (no alert emails)
  # Note: Enabling alerts also enables the local submission port for system-generated mail
  alertEmail = "postmaster";

  # AWS settings (used by Terraform via generated tfvars)
  aws = {
    # Project name (used for AWS resource naming and tagging)
    project = "email-server";

    region = "us-east-1";
    instanceType = "t3.small";
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
    };
  };

  # Container resource limits (memory in MB)
  # Defaults are tuned for t3.micro (1GB RAM) or t3.nano (512MB + 1GB swap)
  # Increase for larger instances or heavier workloads
  resources = {
    opensmtpd.memory = 192;
    dovecot.memory = 192;
    rspamd.memory = 384;
    redis.memory = 192;
  };
}
