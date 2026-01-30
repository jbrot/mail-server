# Network configuration
# nix/nixos/networking.nix

{ config, lib, pkgs, ... }:

{
  # Hostname (will be overridden by configuration.nix)
  networking.hostName = lib.mkDefault "mail";

  # Enable networking
  networking.useDHCP = true;

  # Disable NixOS firewall - we use custom nftables rules for fine-grained control
  # This allows us to distinguish between container->host and external->host traffic
  networking.firewall.enable = false;

  # Custom firewall using nftables
  # Provides fine-grained control over traffic flows:
  # - Container -> Host: DNS only (for aardvark-dns)
  # - External -> Host: SSH, HTTP (ACME)
  # - External -> Container: Allowed (only published ports are routable via Podman NAT)
  # - Container egress: Filtered per-container in mail-networks.nix (imap-egress, rspamd-egress)
  networking.nftables.enable = true;
  networking.nftables.tables.host-firewall = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority 0; policy drop;

        # Allow established/related connections
        ct state established,related accept

        # Allow loopback
        iif lo accept

        # === Container -> Host ===
        # Only allow DNS (required for Podman's aardvark-dns)
        # All container DNS resolution goes through the host
        iifname "podman*" udp dport 53 accept
        iifname "podman*" tcp dport 53 accept
        # Block all other container -> host traffic
        iifname "podman*" drop

        # === External -> Host (services running on host, not in containers) ===
        # ICMP (ping, etc.)
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # SSH
        tcp dport 22 accept

        # HTTP (ACME challenges)
        tcp dport 80 accept

        # Everything else dropped by policy
      }
    '';
  };

  # DNS resolution
  networking.nameservers = [ "169.254.169.253" ]; # AWS DNS

  # Enable IPv6
  networking.enableIPv6 = true;

  # Disable predictable interface names (use eth0)
  networking.usePredictableInterfaceNames = false;
}
