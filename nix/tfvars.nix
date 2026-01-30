# Generate terraform.tfvars content from mail server configuration
{ pkgs, mailServerConfig, mailDns }:

let
  # Get NixOS version from nixpkgs (e.g., "25.11")
  nixosVersion = pkgs.lib.trivial.release;

  # Read validated strings from derivations only if enabled
  # Empty string = disabled (Terraform checks for empty to skip resource creation)
  spfRecord = if mailDns.spfEnabled
    then builtins.readFile mailDns.spfRecord
    else "";
  dmarcRecord = if mailDns.dmarcEnabled
    then builtins.readFile mailDns.dmarcRecord
    else "";

  tfvarsContent = ''
    # Generated from Nix configuration - do not edit manually
    # SPF/DMARC records validated at Nix build time (via IFD)
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

    # SPF/DMARC settings (validated via checkdmarc, empty = disabled)
    spf_record   = "${spfRecord}"
    dmarc_record = "${dmarcRecord}"
  '';
in
pkgs.writeText "from-nix.tfvars" tfvarsContent
