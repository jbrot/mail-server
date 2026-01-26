# Full mail server module - integrates OpenSMTPd, Dovecot, and Rspamd
# nix/nixos/mail-server.nix

{ config, lib, pkgs, ... }:

let
  cfg = config.services.mailServer;

  # Default ECR registry configuration
  defaultEcrRegistry = "123456789012.dkr.ecr.us-east-1.amazonaws.com";
  defaultProjectName = "email-server";

in
{
  imports = [
    ./opensmtpd.nix
    ./dovecot.nix
    ./rspamd.nix
    ./test-network.nix
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

    # Image configuration
    images = {
      opensmtpd = lib.mkOption {
        type = lib.types.str;
        default = "${defaultEcrRegistry}/${defaultProjectName}/opensmtpd:latest";
        description = "OpenSMTPd container image";
      };
      dovecot = lib.mkOption {
        type = lib.types.str;
        default = "${defaultEcrRegistry}/${defaultProjectName}/dovecot:latest";
        description = "Dovecot container image";
      };
      rspamd = lib.mkOption {
        type = lib.types.str;
        default = "${defaultEcrRegistry}/${defaultProjectName}/rspamd:latest";
        description = "Rspamd container image";
      };
      redis = lib.mkOption {
        type = lib.types.str;
        default = "${defaultEcrRegistry}/${defaultProjectName}/redis:latest";
        description = "Redis container image";
      };
    };

    useEcr = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to use ECR for images (enables ECR login service)";
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
    };

    # Debug options
    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable debug logging for all services";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable test network for container communication
    services.testNetwork.enable = true;

    # === Rspamd Configuration ===
    services.rspamdContainer = {
      enable = true;
      image = cfg.images.rspamd;
      redisImage = cfg.images.redis;

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

      # Network configuration (shared test-net)
      networking.networks = [ "test-net" ];
      redisNetworking.networks = [ "test-net" ];
    };

    # === Dovecot Configuration ===
    services.dovecotContainer = {
      enable = true;
      image = cfg.images.dovecot;
      users = cfg.users;

      enableLmtp = true;

      # Enable rspamd integration for spam/ham learning via imap_sieve
      rspamd = {
        enable = true;
        host = "rspamd:11334";
      };

      # Network configuration (shared test-net)
      networking.networks = [ "test-net" ];
      networking.publishPorts = [ "993:993" "143:143" ];
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
      lmtpPort = 24;

      # Enable rspamd filter
      enableRspamd = true;

      # Network configuration (shared test-net)
      networking.networks = [ "test-net" ];
      networking.publishPorts = [ "25:25" "587:587" ];
    };

    # === Service Ordering ===
    # Redis starts first, then rspamd, then dovecot, then opensmtpd
    # All containers depend on network setup
    # When ECR is enabled, all containers depend on ecr-login
    systemd.services.podman-rspamd-redis = {
      after = [ "create-test-network.service" ]
        ++ lib.optionals cfg.useEcr [ "ecr-login.service" ];
      requires = lib.optionals cfg.useEcr [ "ecr-login.service" ];
    };
    systemd.services.podman-rspamd.after = [ "podman-rspamd-redis.service" "create-test-network.service" ];
    systemd.services.podman-dovecot.after = [ "podman-rspamd.service" "create-test-network.service" ];
    systemd.services.podman-opensmtpd.after = [ "podman-dovecot.service" "podman-rspamd.service" "create-test-network.service" ];

    # === ECR Login (for production) ===
    systemd.services.ecr-login = lib.mkIf cfg.useEcr {
      description = "Login to AWS ECR";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      before = [ "podman-rspamd-redis.service" "podman-rspamd.service" "podman-dovecot.service" "podman-opensmtpd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.awscli2}/bin/aws ecr get-login-password --region us-east-1 | \
          ${pkgs.podman}/bin/podman login --username AWS --password-stdin ${defaultEcrRegistry}
      '';
    };

    # Timer to refresh ECR credentials (they expire after 12 hours)
    systemd.timers.ecr-login = lib.mkIf cfg.useEcr {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "0";
        OnUnitActiveSec = "6h";
        RandomizedDelaySec = "5m";
      };
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
