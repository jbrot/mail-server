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
    ./format-data-volume.nix
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

  # Ensure AWS link-local services are reachable via main interface
  # (Podman veth interfaces can claim the 169.254.0.0/16 link-local route)
  # Covers: .253 (VPC DNS resolver), .254 (instance metadata service)
  networking.interfaces.eth0.ipv4.routes = [
    { address = "169.254.169.252"; prefixLength = 30; }
  ];

  # Format and label the EBS data volume on first boot
  services.formatDataVolume.enable = true;
}
