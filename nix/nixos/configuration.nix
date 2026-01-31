# Main NixOS configuration for mail server
# nix/nixos/configuration.nix

{ config, lib, pkgs, self, mailServerConfig, ... }:

{
  # System basics
  system.stateVersion = "24.05";

  # Hostname
  networking.hostName = "mail";

  # Enable flakes
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # System packages
  environment.systemPackages = with pkgs; [
    # Basic utilities
    vim
    htop
    tmux
    git
    curl
    wget
    jq

    # Network tools
    dig
    tcpdump
    nmap
    openssl

    # Mail tools
    swaks  # SMTP testing

    # Container tools
    podman
    skopeo

    # AWS tools
    awscli2
  ];

  # Enable Podman
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;  # Allows using 'docker' commands
    defaultNetwork.settings.dns_enabled = true;
  };

  # Container registry configuration - block all remote registries
  # All images must be loaded from local Nix store archives (docker-archive:)
  # Note: Uses mkForce to override the default registries.conf from containers module
  environment.etc."containers/registries.conf".text = lib.mkForce ''
    # No default search registries - unqualified image names will fail
    unqualified-search-registries = []

    # Block common public registries
    [[registry]]
    location = "docker.io"
    blocked = true

    [[registry]]
    location = "quay.io"
    blocked = true

    [[registry]]
    location = "ghcr.io"
    blocked = true

    [[registry]]
    location = "gcr.io"
    blocked = true

    [[registry]]
    location = "registry.k8s.io"
    blocked = true
  '';

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
      KbdInteractiveAuthentication = false;
    };
  };


  # Create vmail user for mail storage
  users.users.vmail = {
    isSystemUser = true;
    uid = 5000;
    group = "vmail";
    home = "/data/mail";
    createHome = true;
  };
  users.groups.vmail.gid = 5000;

  # ACME (Let's Encrypt) certificate management
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = mailServerConfig.acmeEmail;
    } // lib.optionalAttrs (mailServerConfig.acmeStaging or false) {
      # Use staging server for testing (avoids rate limits, but certs aren't browser-trusted)
      server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    };

    # Certificate for mail server
    certs.${mailServerConfig.hostname} = {
      # Use HTTP-01 challenge
      webroot = "/var/lib/acme/acme-challenge";
      group = "nginx";

      # Copy certs to /data/certs for containers
      postRun = ''
        mkdir -p /data/certs
        cp fullchain.pem /data/certs/
        cp key.pem /data/certs/
        chmod 644 /data/certs/fullchain.pem
        chmod 640 /data/certs/key.pem
        chown root:root /data/certs/*.pem

        # Reload services that use the certificates
        systemctl try-reload-or-restart podman-opensmtpd.service || true
        systemctl try-reload-or-restart podman-dovecot.service || true
      '';
    };
  };

  # Nginx for ACME HTTP-01 challenges
  services.nginx = {
    enable = true;
    virtualHosts.${mailServerConfig.hostname} = {
      locations."/.well-known/acme-challenge" = {
        root = "/var/lib/acme/acme-challenge";
      };
      locations."/" = {
        return = "301 https://$host$request_uri";
      };
    };
  };

  # Create required directories
  systemd.tmpfiles.rules = [
    "d /var/lib/acme/acme-challenge 0755 acme acme -"
    "d /data/mail 0700 vmail vmail -"
    "d /data/certs 0750 root root -"
    "d /data/rspamd 0750 1000 1000 -"  # rspamd user in container
  ];

  # Monit for system monitoring and alerting
  # alertEmail: username (domain added automatically), unset or "" to disable
  services.monitAlerts = {
    enable = true;
    alertEmail = lib.optionalString ((mailServerConfig.alertEmail or "") != "")
      "${mailServerConfig.alertEmail}@${mailServerConfig.domain}";
  };

  # Journald configuration
  services.journald = {
    extraConfig = ''
      SystemMaxUse=500M
      RuntimeMaxUse=100M
    '';
  };

  # Chrony for time sync
  services.chrony.enable = true;

  # Swap file
  swapDevices = [{
    device = "/swapfile";
    size = (mailServerConfig.aws.swapSize or 1) * 1024;  # Config is in GB, swapDevices expects MB
  }];

  # === Mail Server Stack ===
  services.mailServer = {
    enable = true;
    domain = mailServerConfig.domain;
    hostname = mailServerConfig.hostname;
    users = mailServerConfig.users or {};
    aliases = mailServerConfig.aliases or {};
    dkim = (mailServerConfig.dkim or {}) // {
      route53ZoneId = mailServerConfig.aws.route53ZoneId or "";
    };
    localSubmission = mailServerConfig.localSubmission or {};
    resources = mailServerConfig.resources or {};
  };

  # === Mail DNS Records (SPF/DMARC for Terraform) ===
  mailDns = {
    enable = true;
    domain = mailServerConfig.domain;
    spf = mailServerConfig.spf or {};
    dmarc = mailServerConfig.dmarc or {};
  };
}
