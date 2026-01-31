# Format data volume service
# Formats and labels EBS data volume on first boot, skips if already formatted
# nix/nixos/format-data-volume.nix

{ config, lib, pkgs, ... }:

let
  cfg = config.services.formatDataVolume;
in
{
  options.services.formatDataVolume = {
    enable = lib.mkEnableOption "Format data volume service";

    devices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "/dev/xvdf" "/dev/nvme1n1" ];
      example = [ "/dev/vdb" ];
      description = ''
        List of candidate device paths to check. The first existing block device is used.
      '';
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "data";
      description = "Filesystem label to apply";
    };

    fsType = lib.mkOption {
      type = lib.types.str;
      default = "ext4";
      description = "Filesystem type to create";
    };
  };

  config = lib.mkIf cfg.enable {
    # Boot-time service - runs before filesystems are mounted
    systemd.services.format-data-volume = {
      description = "Format and label data volume if needed";
      wantedBy = [ "local-fs-pre.target" ];
      before = [ "local-fs-pre.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        # Find the first existing block device from candidate list
        DEVICE=""
        for dev in ${lib.escapeShellArgs cfg.devices}; do
          if [ -b "$dev" ]; then
            DEVICE="$dev"
            break
          fi
        done

        if [ -z "$DEVICE" ]; then
          echo "No data volume found, skipping"
          exit 0
        fi

        # Get current filesystem type (empty if unformatted)
        FSTYPE=$(${pkgs.util-linux}/bin/blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)
        LABEL=$(${pkgs.util-linux}/bin/blkid -o value -s LABEL "$DEVICE" 2>/dev/null || true)

        if [ -z "$FSTYPE" ]; then
          # No filesystem detected - safe to format
          echo "Formatting $DEVICE as ${cfg.fsType}..."
          ${pkgs.e2fsprogs}/bin/mkfs.${cfg.fsType} -L "${cfg.label}" "$DEVICE"
        elif [ "$FSTYPE" = "${cfg.fsType}" ] && [ "$LABEL" != "${cfg.label}" ]; then
          # Already correct fsType but missing label - just add label
          echo "Adding label to $DEVICE..."
          ${pkgs.e2fsprogs}/bin/e2label "$DEVICE" "${cfg.label}"
        else
          echo "Volume $DEVICE already formatted as $FSTYPE with label '$LABEL', skipping"
        fi
      '';
    };

    # Activation script - runs during nixos-rebuild switch
    # Handles case where volume exists but isn't mounted (e.g., after volume recreation)
    system.activationScripts.formatDataVolume = {
      text = ''
        # Skip if /data is already mounted
        if ${pkgs.util-linux}/bin/mountpoint -q /data 2>/dev/null; then
          exit 0
        fi

        echo "Checking data volume..."

        # Find the first existing block device from candidate list
        DEVICE=""
        for dev in ${lib.escapeShellArgs cfg.devices}; do
          if [ -b "$dev" ]; then
            DEVICE="$dev"
            break
          fi
        done

        if [ -z "$DEVICE" ]; then
          echo "No data volume found"
          exit 0
        fi

        # Get current filesystem type (empty if unformatted)
        FSTYPE=$(${pkgs.util-linux}/bin/blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)

        if [ -z "$FSTYPE" ]; then
          echo "Formatting $DEVICE as ${cfg.fsType}..."
          ${pkgs.e2fsprogs}/bin/mkfs.${cfg.fsType} -L "${cfg.label}" "$DEVICE"
        fi

        # Try to mount /data
        echo "Mounting /data..."
        ${pkgs.util-linux}/bin/mount /data || true
      '';
    };
  };
}
