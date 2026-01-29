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

    ${lib.optionalString (cfg.controller.password != "") ''
    # Password for web UI (generate with: rspamadm pw)
    password = "${cfg.controller.password}";
    ''}
    ${lib.optionalString (cfg.controller.enablePassword != "") ''
    # Enable write access (for learning spam/ham)
    enable_password = "${cfg.controller.enablePassword}";
    ''}
    # Allow passwordless access from trusted networks (localhost and container networks)
    secure_ip = "127.0.0.1";
    secure_ip = "::1";
    secure_ip = "10.0.0.0/8";
    secure_ip = "172.16.0.0/12";
    secure_ip = "192.168.0.0/16";
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
    servers = "${cfg.redis.host}:${toString cfg.redis.port}";
    new_schema = true;

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
    servers = "${cfg.redis.host}:${toString cfg.redis.port}";
  '';

  # Generate options.inc
  optionsInc = pkgs.writeText "options.inc" ''
    # Rspamd general options

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

    # Network configuration for rspamd container
    networking = {
      networks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "List of podman networks to attach";
      };

      publishPorts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Ports to publish (e.g., '11333:11333')";
      };
    };

    # Redis container configuration
    redis = {
      image = lib.mkOption {
        type = lib.types.str;
        description = "Redis container image URI";
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 6379;
        description = "Port for Redis server";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "redis";
        description = "Hostname for Redis server (container name on shared network)";
      };

      networking = {
        networks = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "List of podman networks to attach";
        };

        publishPorts = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Ports to publish (e.g., '6379:6379')";
        };
      };

      resources = {
        memory = lib.mkOption {
          type = lib.types.int;
          default = 256;
          description = "Redis container memory limit in MB";
        };

        memoryReservation = lib.mkOption {
          type = lib.types.int;
          default = 128;
          description = "Redis container memory reservation (soft limit) in MB";
        };

        memoryBuffer = lib.mkOption {
          type = lib.types.int;
          default = 32;
          description = "Memory reserved for Redis process overhead in MB (subtracted from container limit for maxmemory)";
        };

        cpus = lib.mkOption {
          type = lib.types.float;
          default = 0.5;
          description = "CPU limit";
        };

        pidsLimit = lib.mkOption {
          type = lib.types.int;
          default = 50;
          description = "Maximum number of PIDs in the container";
        };
      };
    };

    # Resource limits for rspamd container
    resources = {
      memory = lib.mkOption {
        type = lib.types.int;
        default = 512;
        description = "Rspamd container memory limit in MB";
      };

      memoryReservation = lib.mkOption {
        type = lib.types.int;
        default = 256;
        description = "Rspamd container memory reservation (soft limit) in MB";
      };

      cpus = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "CPU limit";
      };

      pidsLimit = lib.mkOption {
        type = lib.types.int;
        default = 200;
        description = "Maximum number of PIDs in the container";
      };
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

    # Controller passwords (optional - if not set, access is restricted to secure_ip networks)
    controller = {
      password = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Password hash for web UI read access (generate with: rspamadm pw). If empty, only secure_ip networks can access.";
      };

      enablePassword = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Password hash for web UI write access (generate with: rspamadm pw). If empty, write access requires secure_ip.";
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

  config = lib.mkIf cfg.enable (let
    # Capabilities needed by the rspamd container
    # - NET_BIND_SERVICE: bind to ports < 1024 (milter, normal, controller)
    # Note: Redis container runs as user 4000:4000 and needs no capabilities
    rspamdCapabilities = [ "NET_BIND_SERVICE" ];
  in {
    # Redis container for rspamd backend
    virtualisation.oci-containers.containers.rspamd-redis = {
      image = cfg.redis.image;
      autoStart = true;

      extraOptions =
        # Network configuration
        (map (net: "--network=${net}") cfg.redis.networking.networks)
        ++ [ "--hostname=redis" ]
        ++ (map (p: "-p=${p}") cfg.redis.networking.publishPorts)
        ++ [
          # Run as redis user (UID 4000)
          "--user=4000:4000"
          # Resource limits
          "--memory=${toString cfg.redis.resources.memory}m"
          "--memory-reservation=${toString cfg.redis.resources.memoryReservation}m"
          "--cpus=${toString cfg.redis.resources.cpus}"
          "--pids-limit=${toString cfg.redis.resources.pidsLimit}"
        ];

      # Volume mounts
      volumes = [
        "/data/redis:/data/redis"
      ];

      # Calculate Redis maxmemory from container limit minus buffer for overhead
      cmd = [ "--maxmemory" "${toString (cfg.redis.resources.memory - cfg.redis.resources.memoryBuffer)}mb" ];

      # Environment
      environment = {
        TZ = "UTC";
      };
    };

    # Rspamd container
    virtualisation.oci-containers.containers.rspamd = {
      image = cfg.image;
      autoStart = true;

      # Note: rspamd starts as root and drops privileges to rspamd user internally
      extraOptions =
        # Network configuration
        (map (net: "--network=${net}") cfg.networking.networks)
        ++ [ "--hostname=rspamd" ]
        ++ (map (p: "-p=${p}") cfg.networking.publishPorts)
        # Capabilities
        ++ (map (cap: "--cap-add=${cap}") rspamdCapabilities)
        ++ [
          # Resource limits
          "--memory=${toString cfg.resources.memory}m"
          "--memory-reservation=${toString cfg.resources.memoryReservation}m"
          "--cpus=${toString cfg.resources.cpus}"
          "--pids-limit=${toString cfg.resources.pidsLimit}"
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
      restartTriggers = [ cfg.redis.image ];
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";

        # Systemd hardening
        # Note: ProtectSystem omitted - podman needs write access to /var/lib/containers and /etc/containers
        # Note: NoNewPrivileges omitted - podman needs to write /proc/*/uid_map for user namespaces
        # Mount namespace isolation disabled - causes systemd to create separate mount namespaces
        # for ExecStart and ExecStop, breaking netavark's network namespace cleanup
        ProtectHome = false;
        PrivateTmp = false;
        ProtectKernelTunables = false;
        ProtectKernelModules = false;
        # ProtectControlGroups omitted - podman needs to create cgroups for containers
        RestrictSUIDSGID = true;
        # Resource limits handled by container runtime, not systemd
      };
    };

    # Rspamd container service configuration
    systemd.services.podman-rspamd = {
      after = [ "network-online.target" "podman-rspamd-redis.service" ];
      requires = [ "podman-rspamd-redis.service" ];
      restartTriggers = [ cfg.image ] ++
        # Restart when any /etc/rspamd/* config file changes
        (lib.mapAttrsToList (_: entry: entry.source)
          (lib.filterAttrs (name: _: lib.hasPrefix "rspamd/" name) config.environment.etc));
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";

        # Systemd hardening
        # Note: ProtectSystem omitted - podman needs write access to /var/lib/containers and /etc/containers
        # Note: NoNewPrivileges omitted - podman needs to write /proc/*/uid_map for user namespaces
        # Note: CapabilityBoundingSet omitted - podman needs CAP_SETUID/CAP_SETGID for user namespaces
        # Mount namespace isolation disabled - causes systemd to create separate mount namespaces
        # for ExecStart and ExecStop, breaking netavark's network namespace cleanup
        ProtectHome = false;
        PrivateTmp = false;
        ProtectKernelTunables = false;
        ProtectKernelModules = false;
        # ProtectControlGroups omitted - podman needs to create cgroups for containers
        RestrictSUIDSGID = true;
        # Resource limits handled by container runtime, not systemd
      };
    };

    # Create configuration directories
    # UIDs: rspamd=3000, redis=4000 (unique per service for isolation)
    systemd.tmpfiles.rules = [
      "d /etc/rspamd 0755 root root -"
      "d /etc/rspamd/local.d 0755 root root -"
      "d /data/rspamd 0755 3000 3000 -"
      "d /data/rspamd/dkim 0700 3000 3000 -"
      "d /data/redis 0755 4000 4000 -"
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
  });
}
