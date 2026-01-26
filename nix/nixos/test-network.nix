# Reusable module for test container networking
# nix/nixos/test-network.nix
#
# This module creates a bridge network for container communication in VM tests.
# It uses netavark (podman's default network backend) with aardvark-dns for
# inter-container name resolution.
#
# Note: The container services must have ProtectKernelTunables = false to allow
# netavark to modify /proc/sys for networking setup.

{ config, lib, pkgs, ... }:

let
  cfg = config.services.testNetwork;
in
{
  options.services.testNetwork = {
    enable = lib.mkEnableOption "Create test bridge network for containers";
  };

  config = lib.mkIf cfg.enable {
    # Pre-configure sysctl settings for container networking
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    };

    # Use dnsmasq as a local DNS server for the test environment
    # This provides fast-failing DNS for aardvark-dns (no internet in VM tests)
    services.dnsmasq = {
      enable = true;
      settings = {
        # Don't use /etc/resolv.conf or any upstream servers
        no-resolv = true;
        # No upstream servers - return NXDOMAIN immediately for unknown queries
        # This prevents hanging while waiting for unreachable DNS servers

        # Bind only to localhost
        interface = "lo";
        bind-interfaces = true;
        # Return NXDOMAIN for all queries (no upstream forwarding)
        # address = "/#/";  # This would return 0.0.0.0 for everything
        # Instead, just don't configure any servers - dnsmasq will return SERVFAIL/REFUSED

        # Local hostname resolution
        local = "/local/";
        domain = "local";
        expand-hosts = true;
      };
    };

    # Point host DNS to local dnsmasq
    networking.nameservers = lib.mkForce [ "127.0.0.1" ];

    # Create the test network before containers start
    systemd.services.create-test-network = {
      description = "Create test container network";
      wantedBy = [ "multi-user.target" ];
      after = [ "podman.service" "dnsmasq.service" ];
      before = [
        "podman-dovecot.service"
        "podman-opensmtpd.service"
        "podman-rspamd.service"
        "podman-rspamd-redis.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ config.virtualisation.podman.package ];
      script = ''
        # Create test network if it doesn't exist
        if ! podman network exists test-net; then
          podman network create test-net
        fi
      '';
    };
  };
}
