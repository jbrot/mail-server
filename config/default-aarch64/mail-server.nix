# Default mail server configuration for aarch64 (test/example)
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

  # ACME certificate settings
  # Use staging server for testing (avoids rate limits, but certs aren't browser-trusted)
  acmeStaging = true;

  # Target architecture
  architecture = "aarch64-linux";

  # AWS settings (used by Terraform via generated tfvars)
  # Using Graviton instances for better price/performance
  aws = {
    region = "us-east-1";
    instanceType = "t4g.small";
    rootVolumeSize = 8;
    dataVolumeSize = 50;

    # CIDR block for SSH access ("auto" = current IP, or e.g., "1.2.3.4/32")
    adminCidr = "auto";

    # Route53 DNS settings
    # Existing hosted zone ID (leave empty to create a new zone for the domain)
    route53ZoneId = "";
    # Whether to create MX record (set false during migration, true when ready to go live)
    route53CreateMX = false;
  };
}
