# Network configuration
# nix/nixos/networking.nix

{ config, lib, pkgs, ... }:

{
  # Hostname (will be overridden by configuration.nix)
  networking.hostName = lib.mkDefault "mail";

  # Enable networking
  networking.useDHCP = true;

  # Firewall configuration
  networking.firewall = {
    enable = true;

    # Allow incoming connections on mail-related ports
    allowedTCPPorts = [
      22    # SSH
      25    # SMTP
      80    # HTTP (ACME challenges)
      443   # HTTPS (optional)
      465   # SMTPS
      587   # SMTP Submission
      993   # IMAPS
      19999 # Netdata (restrict in production via security group)
    ];

    # Rate limiting for SMTP
    extraCommands = ''
      # Rate limit new SMTP connections
      iptables -A INPUT -p tcp --dport 25 -m state --state NEW -m recent --set
      iptables -A INPUT -p tcp --dport 25 -m state --state NEW -m recent --update --seconds 60 --hitcount 20 -j DROP
    '';
  };

  # DNS resolution
  networking.nameservers = [ "169.254.169.253" ]; # AWS DNS

  # Enable IPv6
  networking.enableIPv6 = true;

  # Disable predictable interface names (use eth0)
  networking.usePredictableInterfaceNames = false;
}
