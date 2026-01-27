# Generate terraform.tfvars content from mail server configuration
{ pkgs, mailServerConfig }:

let
  # Get NixOS version from nixpkgs (e.g., "25.11")
  nixosVersion = pkgs.lib.trivial.release;

  tfvarsContent = ''
    # Generated from Nix configuration - do not edit manually
    # Regenerate with: nix build .#tfvars --override-input mail-server-config path:./config/<name>

    project          = "${mailServerConfig.project}"
    aws_region       = "${mailServerConfig.aws.region}"
    instance_type    = "${mailServerConfig.aws.instanceType}"
    root_volume_size = ${toString mailServerConfig.aws.rootVolumeSize}
    data_volume_size = ${toString mailServerConfig.aws.dataVolumeSize}
    architecture     = "${mailServerConfig.architecture}"
    admin_cidr       = "${mailServerConfig.aws.adminCidr}"
    nixos_version    = "${nixosVersion}"

    # DNS settings
    domain             = "${mailServerConfig.domain}"
    hostname           = "${mailServerConfig.hostname}"
    route53_zone_id    = "${mailServerConfig.aws.route53ZoneId or ""}"
    route53_create_mx  = ${if (mailServerConfig.aws.route53CreateMX or false) then "true" else "false"}
  '';
in
pkgs.writeText "from-nix.tfvars" tfvarsContent
