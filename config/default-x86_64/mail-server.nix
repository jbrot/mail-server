# Default mail server configuration for x86_64 (test/example)
# Copy to config/production/ and modify for your production deployment
{
  # Project name (used for AWS resource naming and tagging)
  project = "email-server";

  # Mail domain settings
  domain = "test.local";
  hostname = "mail.test.local";
  acmeEmail = "postmaster@test.local";

  # Target architecture
  architecture = "x86_64-linux";

  # AWS settings (used by Terraform via generated tfvars)
  aws = {
    region = "us-east-1";
    instanceType = "t3.small";
    rootVolumeSize = 8;
    dataVolumeSize = 50;

    # CIDR block for SSH access ("auto" = current IP, or e.g., "1.2.3.4/32")
    adminCidr = "auto";
  };
}
