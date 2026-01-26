# Default mail server configuration for aarch64 (test/example)
# Copy to config/production/ and modify for your production deployment
{
  # Mail domain settings
  domain = "test.local";
  hostname = "mail.test.local";
  acmeEmail = "postmaster@test.local";

  # Target architecture
  architecture = "aarch64-linux";

  # AWS settings (used by Terraform via generated tfvars)
  # Using Graviton instances for better price/performance
  aws = {
    region = "us-east-1";
    instanceType = "t4g.small";
    dataVolumeSize = 50;
  };
}
