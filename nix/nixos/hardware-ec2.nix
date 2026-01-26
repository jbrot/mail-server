# EC2-specific hardware configuration
# nix/nixos/hardware-ec2.nix

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    # This module provides config.system.build.amazonImage
    "${modulesPath}/../maintainers/scripts/ec2/amazon-image.nix"
  ];

  # EC2 instance settings
  ec2.hvm = true;
  ec2.efi = true;

  # AMI image size - needs to be large enough for NixOS + all container images
  amazonImage.sizeMB = 8192;  # 8 GB

  # Boot configuration
  boot.loader.grub.device = "nodev";
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.efiInstallAsRemovable = true;

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
    options = [ "defaults" "nofail" ];
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
