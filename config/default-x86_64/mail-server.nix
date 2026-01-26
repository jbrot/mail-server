# Default mail server configuration for x86_64 (test/example)
# Copy to config/production/ and modify for your production deployment
{
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
    dataVolumeSize = 50;
  };
}
