# Monit alerting module with configurable thresholds
# nix/nixos/monit-alerts.nix
#
# Provides system and filesystem monitoring with email alerts.
# Thresholds are configurable for testability.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.monitAlerts;

  # Generate filesystem check blocks from the filesystems attrset
  filesystemChecks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: path: ''
      check filesystem ${name} with path ${path}
        if space usage > ${toString cfg.thresholds.diskSpace}% then alert
        if inode usage > ${toString cfg.thresholds.inodeUsage}% then alert
    '') cfg.filesystems
  );

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
    '') cfg.services
  );

  # Build the monit config from options
  monitConfig = ''
    # Check interval (seconds)
    set daemon ${toString cfg.checkInterval}

    # HTTP interface (required for monit CLI commands like 'monit status')
    set httpd port 2812 and
      use address localhost
      allow localhost

${lib.optionalString (cfg.alertEmail != "") ''
    # Mail server configuration
    set mailserver ${cfg.mailServer}

    # Alert recipient (repeat alerts while problem persists)
    set alert ${cfg.alertEmail} with reminder on ${toString cfg.reminderCycles} cycles

    # Event queue for when mail server is temporarily unavailable
    set eventqueue
      basedir /var/lib/monit/events
      slots 100
''}

    # === System checks ===
    check system $HOST
      if loadavg (5min) > ${toString cfg.thresholds.loadAvg} then alert
      if memory usage > ${toString cfg.thresholds.memoryUsage}% then alert
      if swap usage > ${toString cfg.thresholds.swapUsage}% then alert

    # === Filesystem checks ===
    ${filesystemChecks}

    # === Service checks ===
    ${serviceChecks}

    ${cfg.extraConfig}
  '';

in
{
  options.services.monitAlerts = {
    enable = lib.mkEnableOption "Monit system alerts";

    alertEmail = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Email address for alert notifications (empty string to disable email alerts)";
    };

    mailServer = lib.mkOption {
      type = lib.types.str;
      default = "localhost port 10025";
      description = "SMTP server for sending alerts. Default uses local submission port (bypasses spam filtering).";
    };

    checkInterval = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Check interval in seconds";
    };

    reminderCycles = lib.mkOption {
      type = lib.types.int;
      default = 720;
      description = "Repeat alert every N cycles while problem persists (720 = 12h at 60s interval)";
    };

    thresholds = {
      diskSpace = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Disk space usage percentage to trigger alert";
      };

      inodeUsage = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Inode usage percentage to trigger alert";
      };

      memoryUsage = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = "Memory usage percentage to trigger alert";
      };

      swapUsage = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Swap usage percentage to trigger alert";
      };

      loadAvg = lib.mkOption {
        type = lib.types.int;
        default = 4;
        description = "5-minute load average to trigger alert";
      };
    };

    filesystems = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        rootfs = "/";
        data = "/data";
      };
      example = { rootfs = "/"; data = "/data"; };
      description = "Filesystems to monitor (name = path)";
    };

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "podman-opensmtpd" "podman-dovecot" "podman-rspamd" "podman-rspamd-redis" ];
      description = "Systemd services to monitor (alert if not active)";
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
