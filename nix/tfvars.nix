# Generate terraform.tfvars content from mail server configuration
{ pkgs, mailServerConfig }:

let
  # Convert Nix architecture to AWS architecture
  awsArch = if mailServerConfig.architecture == "aarch64-linux" then "arm64" else "x86_64";

  # Get NixOS version from nixpkgs (e.g., "24.05")
  nixosVersion = pkgs.lib.trivial.release;

  tfvarsContent = ''
    # Generated from Nix configuration - do not edit manually
    # Regenerate with: nix build .#tfvars --override-input mail-server-config path:./config/<name>

    project          = "${mailServerConfig.project}"
    aws_region       = "${mailServerConfig.aws.region}"
    instance_type    = "${mailServerConfig.aws.instanceType}"
    root_volume_size = ${toString mailServerConfig.aws.rootVolumeSize}
    data_volume_size = ${toString mailServerConfig.aws.dataVolumeSize}
    architecture     = "${awsArch}"
    admin_cidr       = "${mailServerConfig.aws.adminCidr}"
    nixos_version    = "${nixosVersion}"
  '';
in
pkgs.writeText "from-nix.tfvars" tfvarsContent
