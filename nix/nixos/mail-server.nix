# Full mail server module - integrates OpenSMTPd, Dovecot, and Rspamd
# nix/nixos/mail-server.nix

{ config, lib, pkgs, self, ... }:

let
  cfg = config.services.mailServer;

in
{
  imports = [
    ./opensmtpd.nix
    ./dovecot.nix
    ./rspamd.nix
    ./mail-networks.nix
    ./dkim.nix
  ];

  options.services.mailServer = {
    enable = lib.mkEnableOption "Complete mail server stack";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "example.com";
      description = "Primary email domain";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      example = "mail.example.com";
      description = "Mail server hostname (MX record target)";
    };

    users = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = { "alice" = "$6$..."; "bob" = "$6$..."; };
      description = "Mail users with SHA512-CRYPT password hashes";
    };

    aliases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        "postmaster" = "admin";
        "abuse" = "admin";
      };
      description = "Email aliases (name -> target username)";
    };

    # Image configuration - defaults to local Nix-built images (baked into AMI)
    images = {
      opensmtpd = lib.mkOption {
        type = lib.types.str;
        default = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.opensmtpd-image}";
        description = "OpenSMTPd container image";
      };
      dovecot = lib.mkOption {
        type = lib.types.str;
        default = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.dovecot-image}";
        description = "Dovecot container image";
      };
      rspamd = lib.mkOption {
        type = lib.types.str;
        default = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.rspamd-image}";
        description = "Rspamd container image";
      };
      redis = lib.mkOption {
        type = lib.types.str;
        default = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.redis-image}";
        description = "Redis container image";
      };
    };

    # DKIM configuration
    dkim = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable DKIM signing for outbound mail";
      };

      selector = lib.mkOption {
        type = lib.types.str;
        default = "mail";
        description = "DKIM selector";
      };

      route53ZoneId = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Route53 hosted zone ID for automatic DKIM DNS record creation. Empty to disable.";
      };
    };

    # Debug options
    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug logging for all services";
    };

    # Local submission (for system-generated mail like Monit alerts)
    localSubmission = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable local submission port for system-generated mail (bypasses spam filtering)";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 10025;
        description = "Port for local mail submission (only accessible from localhost)";
      };
    };

    # DNS-based spam filters
    enableDnsFilters = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable DNS-based SMTP filters (rDNS, FCrDNS, dyndns check). Disable for testing without proper DNS.";
    };

    # Container resource limits (memory in MB)
    resources = {
      opensmtpd.memory = lib.mkOption {
        type = lib.types.int;
        default = 192;
        description = "OpenSMTPd container memory limit in MB";
      };

      dovecot.memory = lib.mkOption {
        type = lib.types.int;
        default = 192;
        description = "Dovecot container memory limit in MB";
      };

      rspamd.memory = lib.mkOption {
        type = lib.types.int;
        default = 768;
        description = "Rspamd container memory limit in MB";
      };

      redis.memory = lib.mkOption {
        type = lib.types.int;
        default = 192;
        description = "Redis container memory limit in MB";
      };
    };

  };

  config = lib.mkIf cfg.enable {
    # mail-networks.nix creates 5 isolated networks:
    # - External: mail-smtp-external (OpenSMTPd - full internet for mail delivery)
    # - Filtered: mail-rspamd-external (Rspamd - DNS + rspamd.com only via nftables)
    #             mail-imap-external (Dovecot - inbound only, no egress via nftables)
    # - Internal: mail-internal (OpenSMTPd/Dovecot/Rspamd), mail-rspamd-redis (Rspamd/Redis)

    # === Monit Container Monitoring ===
    # Add container services to Monit for failure alerting
    # Monit's event queue handles the case where OpenSMTPd itself fails
    services.monitAlerts.services.targets = [
      "podman-opensmtpd"
      "podman-dovecot"
      "podman-rspamd"
      "podman-rspamd-redis"
    ];

    # Monitor container memory usage
    services.monitAlerts.containers.targets = [
      "opensmtpd"
      "dovecot"
      "rspamd"
      "rspamd-redis"
    ];

    # === DKIM Key Manager ===
    services.dkimKeyManager = {
      enable = cfg.dkim.enable;
      domain = cfg.domain;
      selector = cfg.dkim.selector;
      route53 = {
        enable = cfg.dkim.route53ZoneId != "";
        zoneId = cfg.dkim.route53ZoneId;
      };
    };

    # === Rspamd Configuration ===
    services.rspamdContainer = {
      enable = true;
      image = cfg.images.rspamd;
      redis.image = cfg.images.redis;

      logLevel = if cfg.debug then "debug" else "info";

      dkim = {
        enable = cfg.dkim.enable;
        selector = cfg.dkim.selector;
      };

      bayes = {
        enable = true;
        autolearn = {
          spamThreshold = 7.0;
          hamThreshold = -0.5;
        };
      };

      # Network: rspamd-external (filtered egress), internal (milter/learning), rspamd-redis
      networking.networks = [ "mail-rspamd-external" "mail-internal" "mail-rspamd-redis" ];
      redis.networking.networks = [ "mail-rspamd-redis" ];

      # Resource limits
      resources.memory = cfg.resources.rspamd.memory;
      redis.resources.memory = cfg.resources.redis.memory;
    };

    # === Dovecot Configuration ===
    services.dovecotContainer = {
      enable = true;
      image = cfg.images.dovecot;
      users = cfg.users;

      enableLmtp = true;

      # Enable rspamd integration for spam/ham learning via imap_sieve
      rspamd.enable = true;

      # Network: imap-external (port publishing, egress blocked), internal (LMTP delivery, spam learning)
      networking.networks = [ "mail-imap-external" "mail-internal" ];
      networking.publishPorts = [ "993:993" "143:143" ];

      # Resource limits
      resources.memory = cfg.resources.dovecot.memory;
    };

    # === OpenSMTPd Configuration ===
    services.opensmtpdContainer = {
      enable = true;
      image = cfg.images.opensmtpd;

      serverDomain = cfg.hostname;
      emailDomain = cfg.domain;

      credentials = cfg.users;
      aliases = cfg.aliases;

      # Deliver via LMTP to Dovecot
      localDelivery = false;

      # Enable rspamd filter
      enableRspamd = true;

      # DNS filters (rDNS/FCrDNS) - configurable for environments without proper DNS
      enableDnsFilters = cfg.enableDnsFilters;

      # Local submission port for system-generated mail (e.g., Monit alerts)
      # Bypasses spam filtering - only accessible from localhost
      localSubmissionPort = if cfg.localSubmission.enable then cfg.localSubmission.port else null;

      # Network: smtp-external (inbound/outbound mail), internal (rspamd filtering, LMTP delivery)
      networking.networks = [ "mail-smtp-external" "mail-internal" ];
      # Port for local system mail (Monit alerts, etc.) bound to localhost only
      networking.publishPorts = [ "25:25" "587:587" ]
        ++ lib.optional cfg.localSubmission.enable "127.0.0.1:${toString cfg.localSubmission.port}:${toString cfg.localSubmission.port}";

      # Resource limits
      resources.memory = cfg.resources.opensmtpd.memory;
    };

    # === Service Ordering ===
    # DKIM key manager runs first, then Redis, then rspamd, then dovecot, then opensmtpd
    # All containers depend on mail-network-setup and restart when it restarts (via PartOf)
    systemd.services.podman-rspamd-redis = {
      after = [ "mail-network-setup.service" ];
      partOf = [ "mail-network-setup.service" ];
    };
    systemd.services.podman-rspamd = {
      after = [ "podman-rspamd-redis.service" "mail-network-setup.service" "dkim-key-manager.service" ];
      partOf = [ "mail-network-setup.service" ];
    };
    systemd.services.podman-dovecot = {
      after = [ "podman-rspamd.service" "mail-network-setup.service" ];
      partOf = [ "mail-network-setup.service" ];
    };
    systemd.services.podman-opensmtpd = {
      after = [ "podman-dovecot.service" "podman-rspamd.service" "mail-network-setup.service" ];
      partOf = [ "mail-network-setup.service" ];
    };

    # === Data Directories ===
    # UIDs: vmail=5000, rspamd=3000, redis=4000 (unique per service for isolation)
    systemd.tmpfiles.rules = [
      "d /data 0755 root root -"
      "d /data/mail 0700 5000 5000 -"
      "d /data/certs 0755 root root -"
      "d /data/rspamd 0755 3000 3000 -"
      "d /data/rspamd/dkim 0700 3000 3000 -"
      "d /data/redis 0755 4000 4000 -"
      "d /data/sieve 0700 5000 5000 -"
    ];

    # === Helper Scripts ===
    environment.systemPackages = [
      # DKIM key generation
      (pkgs.writeShellScriptBin "generate-dkim-key" ''
        set -e
        DOMAIN="''${1:-${cfg.domain}}"
        SELECTOR="''${2:-${cfg.dkim.selector}}"
        KEY_DIR="/data/rspamd/dkim"

        mkdir -p "$KEY_DIR"

        if [ -f "$KEY_DIR/$DOMAIN.$SELECTOR.key" ]; then
          echo "Key already exists: $KEY_DIR/$DOMAIN.$SELECTOR.key"
          echo "Delete it first if you want to regenerate"
          exit 1
        fi

        echo "Generating DKIM key for $DOMAIN with selector $SELECTOR..."
        ${pkgs.rspamd}/bin/rspamadm dkim_keygen -s "$SELECTOR" -d "$DOMAIN" \
          -k "$KEY_DIR/$DOMAIN.$SELECTOR.key" > "$KEY_DIR/$DOMAIN.$SELECTOR.txt"

        # Fix permissions for rspamd container (UID 3000)
        chown 3000:3000 "$KEY_DIR/$DOMAIN.$SELECTOR.key"
        chmod 600 "$KEY_DIR/$DOMAIN.$SELECTOR.key"

        echo ""
        echo "Private key: $KEY_DIR/$DOMAIN.$SELECTOR.key"
        echo ""
        echo "Add this DNS TXT record:"
        cat "$KEY_DIR/$DOMAIN.$SELECTOR.txt"
      '')

      # User password hash generator
      (pkgs.writeShellScriptBin "generate-password-hash" ''
        echo "Enter password to hash:"
        read -s PASSWORD
        echo "$PASSWORD" | ${pkgs.mkpasswd}/bin/mkpasswd -m sha-512 -s
      '')
    ];
  };
}
