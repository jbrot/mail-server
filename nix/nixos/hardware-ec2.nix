# EC2-specific hardware configuration
# nix/nixos/hardware-ec2.nix

{ config, lib, pkgs, modulesPath, mailServerConfig, ... }:

let
  # Determine if we're on an EFI system
  # aarch64 always uses EFI; x86_64 community AMIs typically use BIOS
  isEfi = mailServerConfig.architecture == "aarch64-linux";
in
{
  imports = [
    # This module provides config.system.build.amazonImage
    "${modulesPath}/../maintainers/scripts/ec2/amazon-image.nix"
  ];

  # EC2 instance settings
  # amazon-image.nix configures the bootloader based on ec2.efi:
  # - x86_64 (efi=false): BIOS boot, grub.device="/dev/xvda"
  # - aarch64 (efi=true): EFI boot, grub.device="nodev"
  ec2.hvm = true;
  ec2.efi = isEfi;

  # Kernel modules for AWS
  boot.initrd.availableKernelModules = [
    "xen_blkfront"
    "xen_netfront"
    "nvme"
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
  ];

  # EBS data volume mount
  # Device name may vary - /dev/xvdf or /dev/nvme1n1 depending on instance type
  fileSystems."/data" = {
    device = "/dev/disk/by-label/data";
    fsType = "ext4";
    options = [ "defaults" ];
    autoFormat = false;
  };

  # Swap (optional, but recommended)
  swapDevices = [];

  # Hardware settings - architecture set by flake based on config

  # Time zone
  time.timeZone = "UTC";

  # Systemd service to format and label the data volume on first boot
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
      # Find the EBS data volume (could be xvdf or nvme1n1)
      DEVICE=""
      for dev in /dev/xvdf /dev/nvme1n1; do
        if [ -b "$dev" ]; then
          DEVICE="$dev"
          break
        fi
      done

      if [ -z "$DEVICE" ]; then
        echo "No data volume found, skipping"
        exit 0
      fi

      # Check if already formatted
      if ! ${pkgs.e2fsprogs}/bin/blkid -o value -s TYPE "$DEVICE" | grep -q ext4; then
        echo "Formatting $DEVICE as ext4..."
        ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L data "$DEVICE"
      elif ! ${pkgs.e2fsprogs}/bin/blkid -o value -s LABEL "$DEVICE" | grep -q data; then
        echo "Adding label to $DEVICE..."
        ${pkgs.e2fsprogs}/bin/e2label "$DEVICE" data
      fi
    '';
  };
}
