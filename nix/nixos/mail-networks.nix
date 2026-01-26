# Mail server network isolation module
# nix/nixos/mail-networks.nix
#
# Creates point-to-point bridge networks for container isolation:
# - External networks: Allow outbound internet access
# - Internal networks: Container-to-container only, no external access

{ config, lib, pkgs, ... }:

let
  # Network definitions
  networks = {
    # External networks (can reach internet)
    smtp-external = {
      internal = false;
      description = "OpenSMTPd external access (ports 25, 587)";
    };
    imap-external = {
      internal = false;
      description = "Dovecot external access (ports 143, 993)";
    };
    rspamd-external = {
      internal = false;
      description = "Rspamd external access (RBL/DNS lookups)";
    };

    # Internal networks (container-to-container only)
    smtp-rspamd = {
      internal = true;
      description = "OpenSMTPd <-> Rspamd (milter filtering)";
    };
    smtp-lmtp = {
      internal = true;
      description = "OpenSMTPd <-> Dovecot (LMTP delivery)";
    };
    rspamd-redis = {
      internal = true;
      description = "Rspamd <-> Redis (Bayes/cache storage)";
    };
    dovecot-rspamd = {
      internal = true;
      description = "Dovecot <-> Rspamd (spam/ham learning)";
    };
  };

  # Generate network creation commands
  networkCreateCmds = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: opts:
    let
      fullName = "mail-${name}";
      internalFlag = if opts.internal then "--internal" else "";
    in ''
      if ! ${pkgs.podman}/bin/podman network exists ${fullName}; then
        echo "Creating network ${fullName}..."
        ${pkgs.podman}/bin/podman network create ${internalFlag} ${fullName}
      fi
    ''
  ) networks);

in
{
  # Create networks before any container starts
  systemd.services.mail-network-setup = {
    description = "Create mail server podman networks";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    before = [
      "podman-opensmtpd.service"
      "podman-dovecot.service"
      "podman-rspamd.service"
      "podman-rspamd-redis.service"
    ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = networkCreateCmds;
  };
}
