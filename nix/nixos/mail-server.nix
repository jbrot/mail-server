# Mail server module - Podman containers for OpenSMTPd, Dovecot, Rspamd
# nix/nixos/mail-server.nix

{ config, lib, pkgs, ... }:

let
  # ECR registry configuration
  # These should be set via environment or Terraform output
  ecrRegistry = "123456789012.dkr.ecr.us-east-1.amazonaws.com";
  projectName = "email-server";

  # Image references (update after pushing to ECR)
  images = {
    opensmtpd = "${ecrRegistry}/${projectName}/opensmtpd:latest";
    dovecot = "${ecrRegistry}/${projectName}/dovecot:latest";
    rspamd = "${ecrRegistry}/${projectName}/rspamd:latest";
  };

in
{
  # ECR login service - refreshes credentials periodically
  systemd.services.ecr-login = {
    description = "Login to AWS ECR";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.awscli2}/bin/aws ecr get-login-password --region us-east-1 | \
        ${pkgs.podman}/bin/podman login --username AWS --password-stdin ${ecrRegistry}
    '';
  };

  # Timer to refresh ECR credentials (they expire after 12 hours)
  systemd.timers.ecr-login = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "0";
      OnUnitActiveSec = "6h";  # Refresh every 6 hours
      RandomizedDelaySec = "5m";
    };
  };

  # Rspamd container - starts first (other services depend on it)
  virtualisation.oci-containers.containers.rspamd = {
    image = images.rspamd;
    autoStart = true;

    # Use host network for simplicity
    extraOptions = [
      "--network=host"
      "--cap-add=NET_BIND_SERVICE"
    ];

    # Volume mounts
    volumes = [
      "/data/rspamd:/data/rspamd"
      "/etc/rspamd/local.d:/etc/rspamd/local.d:ro"
    ];

    # Environment
    environment = {
      TZ = "UTC";
    };
  };

  # Dovecot container - IMAP and LMTP
  virtualisation.oci-containers.containers.dovecot = {
    image = images.dovecot;
    autoStart = true;

    # Use host network
    extraOptions = [
      "--network=host"
      "--cap-add=NET_BIND_SERVICE"
      "--cap-add=SETUID"
      "--cap-add=SETGID"
    ];

    # Volume mounts
    volumes = [
      "/data/mail:/data/mail"
      "/data/certs:/data/certs:ro"
      "/etc/dovecot:/etc/dovecot:ro"
    ];

    # Environment
    environment = {
      TZ = "UTC";
    };

    # Wait for rspamd
    dependsOn = [ "rspamd" ];
  };

  # OpenSMTPd container - SMTP
  virtualisation.oci-containers.containers.opensmtpd = {
    image = images.opensmtpd;
    autoStart = true;

    # Use host network
    extraOptions = [
      "--network=host"
      "--cap-add=NET_BIND_SERVICE"
      "--cap-add=SETUID"
      "--cap-add=SETGID"
    ];

    # Volume mounts
    volumes = [
      "/data/mail:/data/mail"
      "/data/certs:/data/certs:ro"
      "/etc/smtpd:/etc/smtpd:ro"
    ];

    # Environment
    environment = {
      TZ = "UTC";
    };

    # Wait for dovecot and rspamd
    dependsOn = [ "dovecot" "rspamd" ];
  };

  # Container service dependencies and ordering
  systemd.services.podman-rspamd = {
    after = [ "ecr-login.service" "network-online.target" ];
    requires = [ "ecr-login.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  systemd.services.podman-dovecot = {
    after = [ "ecr-login.service" "podman-rspamd.service" "network-online.target" ];
    requires = [ "ecr-login.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  systemd.services.podman-opensmtpd = {
    after = [ "ecr-login.service" "podman-dovecot.service" "podman-rspamd.service" "network-online.target" ];
    requires = [ "ecr-login.service" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Create configuration directories and files
  systemd.tmpfiles.rules = [
    # Rspamd config directory
    "d /etc/rspamd 0755 root root -"
    "d /etc/rspamd/local.d 0755 root root -"
    "d /etc/rspamd/override.d 0755 root root -"

    # Dovecot config directory
    "d /etc/dovecot 0755 root root -"

    # OpenSMTPd config directory
    "d /etc/smtpd 0755 root root -"
  ];

  # Deploy configuration files
  environment.etc = {
    # OpenSMTPd configuration
    "smtpd/smtpd.conf" = {
      source = ../config/smtpd.conf;
      mode = "0644";
    };

    # OpenSMTPd aliases (empty by default)
    "smtpd/aliases" = {
      text = ''
        # Aliases file
        # Format: alias: target
        postmaster: root
        abuse: root
        root: admin@example.com
      '';
      mode = "0644";
    };

    # OpenSMTPd domains
    "smtpd/domains" = {
      text = ''
        # Virtual domains (one per line)
        example.com
      '';
      mode = "0644";
    };

    # OpenSMTPd virtual users mapping
    "smtpd/virtuals" = {
      text = ''
        # Virtual user mapping
        # Format: user@domain: vmail
        # All mail delivered to vmail user, organized by domain/user in Maildir
        @example.com    vmail
      '';
      mode = "0644";
    };

    # Dovecot configuration
    "dovecot/dovecot.conf" = {
      source = ../config/dovecot.conf;
      mode = "0644";
    };

    # Dovecot users file (password hashes)
    "dovecot/users" = {
      text = ''
        # User database for Dovecot authentication
        # Format: user@domain:{scheme}password
        # Generate password hash with: doveadm pw -s SHA512-CRYPT
        # Example:
        # user@example.com:{SHA512-CRYPT}$6$...
      '';
      mode = "0600";
    };

    # Rspamd local.d configurations
    "rspamd/local.d/worker-normal.inc" = {
      source = ../config/rspamd/worker-normal.inc;
      mode = "0644";
    };

    "rspamd/local.d/worker-proxy.inc" = {
      source = ../config/rspamd/worker-proxy.inc;
      mode = "0644";
    };

    "rspamd/local.d/worker-controller.inc" = {
      source = ../config/rspamd/worker-controller.inc;
      mode = "0644";
    };

    "rspamd/local.d/dkim_signing.conf" = {
      source = ../config/rspamd/dkim_signing.conf;
      mode = "0644";
    };

    "rspamd/local.d/classifier-bayes.conf" = {
      source = ../config/rspamd/classifier-bayes.conf;
      mode = "0644";
    };

    "rspamd/local.d/logging.inc" = {
      source = ../config/rspamd/logging.inc;
      mode = "0644";
    };

    "rspamd/local.d/actions.conf" = {
      source = ../config/rspamd/actions.conf;
      mode = "0644";
    };

    "rspamd/local.d/options.inc" = {
      source = ../config/rspamd/options.inc;
      mode = "0644";
    };
  };

  # DKIM key generation helper script
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "generate-dkim-key" ''
      set -e
      DOMAIN="''${1:-example.com}"
      SELECTOR="''${2:-mail}"
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

      # Fix permissions
      chown 1000:1000 "$KEY_DIR/$DOMAIN.$SELECTOR.key"
      chmod 600 "$KEY_DIR/$DOMAIN.$SELECTOR.key"

      echo ""
      echo "Private key: $KEY_DIR/$DOMAIN.$SELECTOR.key"
      echo ""
      echo "Add this DNS TXT record:"
      cat "$KEY_DIR/$DOMAIN.$SELECTOR.txt"
    '')
  ];
}
