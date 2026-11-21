# Monit alerting module with configurable thresholds
# nix/nixos/monit-alerts.nix
#
# Provides system and filesystem monitoring with email alerts.
# Options are grouped by alert type for clarity.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.monitAlerts;

  # Generate filesystem check blocks from the filesystem targets attrset
  filesystemChecks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: path: ''
      check filesystem ${name} with path ${path}
        if space usage > ${toString cfg.filesystems.spaceThreshold}% then alert
        if inode usage > ${toString cfg.filesystems.inodeThreshold}% then alert
    '') cfg.filesystems.targets
  );

  # Script to check container memory usage
  # Returns non-zero if container memory usage exceeds threshold
  containerMemoryScript = pkgs.writeShellScript "check-container-memory" ''
    CONTAINER="$1"
    THRESHOLD="$2"

    # Get memory usage percentage from podman stats
    MEM_PCT=$(${pkgs.podman}/bin/podman stats --no-stream --format "{{.MemPerc}}" "$CONTAINER" 2>/dev/null | tr -d '%')

    if [ -z "$MEM_PCT" ]; then
      echo "Container $CONTAINER not found or not running"
      exit 1
    fi

    # Compare as integers (remove decimal part)
    MEM_INT=''${MEM_PCT%.*}
    if [ "$MEM_INT" -ge "$THRESHOLD" ]; then
      echo "Container $CONTAINER memory usage is ''${MEM_PCT}% (threshold: ''${THRESHOLD}%)"
      exit 2
    fi

    echo "Container $CONTAINER memory usage is ''${MEM_PCT}%"
    exit 0
  '';

  # Script to check for recent OOM kills in the kernel journal
  # Returns non-zero if OOM kill detected in the last check interval
  oomCheckScript = pkgs.writeShellScript "check-oom-kills" ''
    SINCE="$1"

    # Check kernel messages for OOM kills
    OOM_MSG=$(${pkgs.systemd}/bin/journalctl -k --since "$SINCE" 2>/dev/null | grep -i "out of memory\|oom-kill\|killed process")

    if [ -n "$OOM_MSG" ]; then
      echo "OOM kill detected: $OOM_MSG"
      exit 1
    fi

    exit 0
  '';

  # Script to check systemd service health
  # Returns non-zero if service is not active OR has been restarted (NRestarts > 0)
  # Admin can clear restart count with: systemctl reset-failed <service>
  serviceCheckScript = pkgs.writeShellScript "check-systemd-service" ''
    SERVICE="$1"

    # Check if service is active
    if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "$SERVICE"; then
      echo "$SERVICE is not active"
      exit 1
    fi

    # Check if service has been restarted (indicates a past crash)
    RESTARTS=$(${pkgs.systemd}/bin/systemctl show "$SERVICE" -p NRestarts --value)
    if [ "$RESTARTS" -gt 0 ]; then
      echo "$SERVICE has restarted $RESTARTS time(s) - clear with: systemctl reset-failed $SERVICE"
      exit 2
    fi

    exit 0
  '';

  # Generate service check blocks for systemd services
  serviceChecks = lib.concatStringsSep "\n" (
    map (name: ''
      check program ${name} with path "${serviceCheckScript} ${name}.service"
        if status != 0 then alert
    '') cfg.services.targets
  );

  # Generate container memory check blocks
  containerMemoryChecks = lib.concatStringsSep "\n" (
    map (name: ''
      check program ${name}-memory with path "${containerMemoryScript} ${name} ${toString cfg.containers.memoryThreshold}"
        if status != 0 then alert
    '') cfg.containers.targets
  );

  # OOM kill check (looks back 2x check interval to avoid missing events)
  oomLookback = if cfg.oom.lookbackSeconds != null then cfg.oom.lookbackSeconds else cfg.checkInterval * 2;
  oomCheck = lib.optionalString cfg.oom.enable ''
    check program oom-killer with path "${oomCheckScript} '${toString oomLookback} seconds ago'"
      if status != 0 then alert
  '';

  # System checks (memory, swap, load average)
  systemCheck = lib.optionalString cfg.system.enable ''
    check system $HOST
      if loadavg (5min) > ${toString cfg.system.loadAvgThreshold} then alert
      if memory usage > ${toString cfg.system.memoryThreshold}% then alert
      if swap usage > ${toString cfg.system.swapThreshold}% then alert
  '';

  # Build the monit config from options
  monitConfig = ''
    # Check interval (seconds)
    set daemon ${toString cfg.checkInterval}

    # HTTP interface (required for monit CLI commands like 'monit status')
    set httpd port ${toString cfg.port} and
      use address localhost
      allow localhost

${lib.optionalString (cfg.alert.email != "") ''
    # Mail server configuration
    set mailserver ${cfg.alert.mailServer}

    # Alert recipient (repeat alerts while problem persists)
    set alert ${cfg.alert.email} with reminder on ${toString cfg.alert.reminderCycles} cycles

    # Event queue for when mail server is temporarily unavailable
    set eventqueue
      basedir /var/lib/monit/events
      slots 100
''}

    # === System checks ===
    ${systemCheck}

    # === Filesystem checks ===
    ${filesystemChecks}

    # === Service checks ===
    ${serviceChecks}

    # === Container memory checks ===
    ${containerMemoryChecks}

    # === OOM kill detection ===
    ${oomCheck}

    ${cfg.extraConfig}
  '';

in
{
  options.services.monitAlerts = {
    enable = lib.mkEnableOption "Monit system alerts";

    checkInterval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Check interval in seconds";
    };

    port = lib.mkOption {
      type = lib.types.int;
      default = 2812;
      description = "HTTP port for monit CLI commands (localhost only)";
    };

    # === Alert delivery options ===
    alert = {
      email = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Email address for alert notifications (empty string to disable email alerts)";
      };

      mailServer = lib.mkOption {
        type = lib.types.str;
        default = "localhost port 10025";
        description = "SMTP server for sending alerts. Default uses local submission port (bypasses spam filtering).";
      };

      reminderCycles = lib.mkOption {
        type = lib.types.int;
        default = 720;
        description = "Repeat alert every N cycles while problem persists (720 = 12h at 60s interval)";
      };
    };

    # === System resource alerts ===
    system = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable system resource monitoring (memory, swap, load average)";
      };

      memoryThreshold = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = "Memory usage percentage to trigger alert";
      };

      swapThreshold = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Swap usage percentage to trigger alert";
      };

      loadAvgThreshold = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "5-minute load average to trigger alert";
      };
    };

    # === Filesystem alerts ===
    filesystems = {
      targets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          rootfs = "/";
          data = "/data";
        };
        example = { rootfs = "/"; data = "/data"; };
        description = "Filesystems to monitor (name = path)";
      };

      spaceThreshold = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Disk space usage percentage to trigger alert";
      };

      inodeThreshold = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Inode usage percentage to trigger alert";
      };
    };

    # === Systemd service alerts ===
    services = {
      targets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "podman-opensmtpd" "podman-dovecot" "podman-rspamd" "podman-rspamd-redis" ];
        description = "Systemd services to monitor (alert if not active or has restarted)";
      };
    };

    # === Container memory alerts ===
    containers = {
      targets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "opensmtpd" "dovecot" "rspamd" "rspamd-redis" ];
        description = "Podman containers to monitor for memory usage";
      };

      memoryThreshold = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Container memory usage percentage to trigger alert";
      };
    };

    # === OOM kill detection ===
    oom = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Alert when OOM killer terminates a process";
      };

      lookbackSeconds = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "Seconds to look back for OOM kills. Defaults to checkInterval * 2.";
      };
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional Monit configuration to append";
    };
  };

  config = lib.mkIf cfg.enable {
    # Enable Monit with generated config
    services.monit = {
      enable = true;
      config = monitConfig;
    };

    # Create event queue directory
    systemd.tmpfiles.rules = [
      "d /var/lib/monit/events 0700 root root -"
    ];
  };
}
