# Default mail server configuration for x86_64 (test/example)
# Copy to config/production/ and modify for your production deployment
{
  # Project name (used for AWS resource naming and tagging)
  project = "email-server";

  # Mail domain settings
  domain = "test.local";
  hostname = "mail.test.local";
  acmeEmail = "admin@example.com";  # Your contact email for Let's Encrypt notifications

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

  # Local submission port for system-generated mail (e.g., Monit alerts)
  # This port bypasses spam filtering and is only accessible from localhost
  localSubmission = {
    enable = true;   # default: true
    port = 10025;    # default: 10025
  };

  # Monitoring alerts (Monit)
  # Username for system alerts (disk space, memory, etc.) - domain is added automatically
  # Set to "postmaster" to send alerts to postmaster@<domain>
  # Default: disabled (no alert emails)
  alertEmail = "postmaster";

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

  # ACME certificate settings
  # Use staging server for testing (avoids rate limits, but certs aren't browser-trusted)
  acmeStaging = true;

  # Target architecture
  architecture = "x86_64-linux";

  # AWS settings (used by Terraform via generated tfvars)
  aws = {
    region = "us-east-1";
    instanceType = "t3.small";
    rootVolumeSize = 8;
    dataVolumeSize = 50;
    swapSize = 1;  # GB

    # CIDR block for SSH access ("auto" = current IP, or e.g., "1.2.3.4/32")
    adminCidr = "auto";

    # Route53 DNS settings
    # Existing hosted zone ID (leave empty to create a new zone for the domain)
    route53ZoneId = "";
    # Whether to create MX record (set false during migration, true when ready to go live)
    route53CreateMX = false;
  };
}
