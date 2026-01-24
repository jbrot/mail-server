# Standalone Rspamd container service module
# nix/nixos/rspamd.nix

{ config, lib, pkgs, ... }:

let
  cfg = config.services.rspamdContainer;

  # Generate worker-proxy.inc
  workerProxyInc = pkgs.writeText "worker-proxy.inc" ''
    # Rspamd proxy worker configuration
    # Milter mode for OpenSMTPd filter
    bind_socket = "0.0.0.0:${toString cfg.milterPort}";
    milter = yes;
    timeout = 120s;
    upstream "local" {
      default = yes;
      self_scan = yes;
    }
  '';

  # Generate worker-normal.inc
  workerNormalInc = pkgs.writeText "worker-normal.inc" ''
    # Rspamd normal worker configuration
    bind_socket = "0.0.0.0:${toString cfg.normalPort}";
  '';

  # Generate worker-controller.inc
  workerControllerInc = pkgs.writeText "worker-controller.inc" ''
    # Rspamd controller worker configuration
    # Web UI and management interface
    bind_socket = "0.0.0.0:${toString cfg.controllerPort}";

    # Password for web UI (generate with: rspamadm pw)
    password = "${cfg.controller.password}";

    # Enable write access (for learning spam/ham)
    enable_password = "${cfg.controller.enablePassword}";
  '';

  # Generate actions.conf
  actionsConf = pkgs.writeText "actions.conf" ''
    # Rspamd actions configuration
    # Score thresholds for actions
    reject = ${toString cfg.actions.reject};
    add_header = ${toString cfg.actions.addHeader};
    greylist = ${toString cfg.actions.greylist};
  '';

  # Generate dkim_signing.conf
  dkimSigningConf = pkgs.writeText "dkim_signing.conf" ''
    # DKIM signing configuration
    enabled = ${if cfg.dkim.enable then "true" else "false"};

    # Path to DKIM private keys
    path = "${cfg.dkim.keyPath}";

    # Default selector
    selector = "${cfg.dkim.selector}";

    # Sign outgoing mail
    sign_local = true;
    sign_inbound = false;

    # Use domain from envelope sender
    use_domain = "envelope";
    use_esld = false;

    # Allow signing for all domains we host
    allow_username_mismatch = true;
  '';

  # Generate classifier-bayes.conf
  classifierBayesConf = pkgs.writeText "classifier-bayes.conf" ''
    # Bayes classifier configuration
    ${lib.optionalString (!cfg.bayes.enable) "enabled = false;"}

    # Use Redis backend for Bayes data
    backend = "redis";
    servers = "127.0.0.1:${toString cfg.redisPort}";

    # Auto-learn from high-confidence results
    autolearn {
      spam_threshold = ${toString cfg.bayes.autolearn.spamThreshold};
      ham_threshold = ${toString cfg.bayes.autolearn.hamThreshold};
    }

    # Minimum learns before using Bayes
    min_learns = 200;
  '';

  # Generate redis.conf for rspamd global Redis settings
  redisConf = pkgs.writeText "redis.conf" ''
    # Redis configuration for rspamd
    servers = "127.0.0.1:${toString cfg.redisPort}";
  '';

  # Generate options.inc
  optionsInc = pkgs.writeText "options.inc" ''
    # Rspamd general options

    # DNS settings
    dns {
      nameserver = [${lib.concatMapStringsSep ", " (s: "\"${s}\"") cfg.dnsServers}];
      timeout = 5s;
      retransmits = 2;
    }

    # Local networks (trusted)
    local_addrs = [${lib.concatMapStringsSep ", " (s: "\"${s}\"") cfg.localNetworks}];
  '';

  # Generate logging.inc
  loggingInc = pkgs.writeText "logging.inc" ''
    # Rspamd logging configuration
    # Log to stderr (for container logging)
    type = "console";
    level = "${cfg.logLevel}";

    # Log format
    log_format = "[%t] <%p> %m";
  '';

in
{
  options.services.rspamdContainer = {
    enable = lib.mkEnableOption "Rspamd container";

    image = lib.mkOption {
      type = lib.types.str;
      description = "Container image URI";
    };

    redisImage = lib.mkOption {
      type = lib.types.str;
      description = "Redis container image URI";
    };

    redisPort = lib.mkOption {
      type = lib.types.int;
      default = 6379;
      description = "Port for Redis server";
    };

    redisMaxMemory = lib.mkOption {
      type = lib.types.str;
      default = "256mb";
      description = "Maximum memory for Redis (e.g., '256mb', '1gb')";
    };

    # Ports
    milterPort = lib.mkOption {
      type = lib.types.int;
      default = 11332;
      description = "Port for milter/proxy (OpenSMTPd filter)";
    };

    normalPort = lib.mkOption {
      type = lib.types.int;
      default = 11333;
      description = "Port for normal worker (REST API)";
    };

    controllerPort = lib.mkOption {
      type = lib.types.int;
      default = 11334;
      description = "Port for controller (Web UI)";
    };

    # Action thresholds
    actions = {
      reject = lib.mkOption {
        type = lib.types.number;
        default = 15;
        description = "Score threshold for rejecting mail";
      };

      addHeader = lib.mkOption {
        type = lib.types.number;
        default = 6;
        description = "Score threshold for adding spam header";
      };

      greylist = lib.mkOption {
        type = lib.types.number;
        default = 4;
        description = "Score threshold for greylisting";
      };
    };

    # DKIM signing
    dkim = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable DKIM signing";
      };

      selector = lib.mkOption {
        type = lib.types.str;
        default = "mail";
        description = "DKIM selector";
      };

      keyPath = lib.mkOption {
        type = lib.types.str;
        default = "/data/rspamd/dkim/$domain.$selector.key";
        description = "Path template for DKIM private keys";
      };
    };

    # Bayes classifier
    bayes = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable Bayes classifier";
      };

      autolearn = {
        spamThreshold = lib.mkOption {
          type = lib.types.number;
          default = 7.0;
          description = "Score threshold for auto-learning spam";
        };

        hamThreshold = lib.mkOption {
          type = lib.types.number;
          default = -0.5;
          description = "Score threshold for auto-learning ham";
        };
      };
    };

    # Controller passwords
    controller = {
      password = lib.mkOption {
        type = lib.types.str;
        default = "$2$changeme";
        description = "Password hash for web UI read access (generate with: rspamadm pw)";
      };

      enablePassword = lib.mkOption {
        type = lib.types.str;
        default = "$2$changeme";
        description = "Password hash for web UI write access (generate with: rspamadm pw)";
      };
    };

    # Network settings
    localNetworks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "127.0.0.0/8"
        "::1"
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
      ];
      description = "Trusted local networks";
    };

    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "8.8.8.8" "1.1.1.1" ];
      description = "DNS servers for RBL lookups";
    };

    # Logging
    logLevel = lib.mkOption {
      type = lib.types.enum [ "error" "warning" "notice" "info" "debug" ];
      default = "info";
      description = "Log level";
    };

    # Extra config files
    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = { "milter_headers.conf" = "extended_spam_headers = true;"; };
      description = "Additional config files for local.d (filename -> content)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Redis container for rspamd backend
    virtualisation.oci-containers.containers.rspamd-redis = {
      image = cfg.redisImage;
      autoStart = true;

      # Use host network for simplicity
      extraOptions = [
        "--network=host"
      ];

      # Volume mounts
      volumes = [
        "/data/redis:/data/redis"
      ];

      # Pass maxmemory as command-line argument
      cmd = [ "--maxmemory" cfg.redisMaxMemory ];

      # Environment
      environment = {
        TZ = "UTC";
      };
    };

    # Rspamd container
    virtualisation.oci-containers.containers.rspamd = {
      image = cfg.image;
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

    # Redis container service configuration
    systemd.services.podman-rspamd-redis = {
      after = [ "network-online.target" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # Rspamd container service configuration
    systemd.services.podman-rspamd = {
      after = [ "network-online.target" "podman-rspamd-redis.service" ];
      requires = [ "podman-rspamd-redis.service" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # Create configuration directories
    systemd.tmpfiles.rules = [
      "d /etc/rspamd 0755 root root -"
      "d /etc/rspamd/local.d 0755 root root -"
      "d /data/rspamd 0755 1000 1000 -"
      "d /data/rspamd/dkim 0700 1000 1000 -"
      "d /data/redis 0755 1000 1000 -"
    ];

    # Deploy configuration files
    environment.etc = {
      "rspamd/local.d/worker-proxy.inc" = {
        source = workerProxyInc;
        mode = "0644";
      };

      "rspamd/local.d/worker-normal.inc" = {
        source = workerNormalInc;
        mode = "0644";
      };

      "rspamd/local.d/worker-controller.inc" = {
        source = workerControllerInc;
        mode = "0644";
      };

      "rspamd/local.d/actions.conf" = {
        source = actionsConf;
        mode = "0644";
      };

      "rspamd/local.d/dkim_signing.conf" = {
        source = dkimSigningConf;
        mode = "0644";
      };

      "rspamd/local.d/classifier-bayes.conf" = {
        source = classifierBayesConf;
        mode = "0644";
      };

      "rspamd/local.d/options.inc" = {
        source = optionsInc;
        mode = "0644";
      };

      "rspamd/local.d/logging.inc" = {
        source = loggingInc;
        mode = "0644";
      };

      "rspamd/local.d/redis.conf" = {
        source = redisConf;
        mode = "0644";
      };
    } // lib.mapAttrs' (name: content: {
      name = "rspamd/local.d/${name}";
      value = {
        text = content;
        mode = "0644";
      };
    }) cfg.extraConfig;
  };
}
