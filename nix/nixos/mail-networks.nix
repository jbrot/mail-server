# Mail server network isolation module
# nix/nixos/mail-networks.nix
#
# Creates point-to-point bridge networks for container isolation:
# - External networks: Allow outbound internet access (OpenSMTPd only for mail delivery)
# - Internal networks: Container-to-container only, no external access
# - Filtered networks: Limited egress (Rspamd: DNS + rspamd.com only)
#
# Egress policy:
# - OpenSMTPd: Full internet (required for mail delivery)
# - Dovecot: Blocked (only on internal networks)
# - Redis: Blocked (only on mail-rspamd-redis internal network)
# - Rspamd: DNS (port 53) + HTTP/HTTPS to rspamd.com only (nftables filtering)

{ config, lib, pkgs, ... }:

let
  # Fixed subnets for filtered networks (allows nftables filtering by source IP)
  # Using 10.89.10x.0/24 range to avoid conflicts with auto-assigned subnets
  rspamdExternalSubnet = "10.89.100.0/24";
  imapExternalSubnet = "10.89.101.0/24";

  # Script to resolve rspamd service IPs and populate the nftables set
  # Used by both the initial setup service and the hourly refresh timer
  rspamdEgressScript = ''
    # Resolve all domains rspamd needs to reach via HTTP/HTTPS/fuzzy
    # rspamd.com subdomains:
    #   HTTP/HTTPS: rspamd.com, maps.rspamd.com, updates.rspamd.com
    #   Fuzzy hash (port 11335): fuzzy1.rspamd.com, fuzzy2.rspamd.com
    #   DNS-based (included for completeness): asn.rspamd.com, asn6.rspamd.com, bl.rspamd.com, uribl.rspamd.com, email.rspamd.com, phishtank.rspamd.com
    # External services:
    #   SURBL hashbl map: sa-update.surbl.org
    ALLOWED_DOMAINS="rspamd.com maps.rspamd.com updates.rspamd.com fuzzy1.rspamd.com fuzzy2.rspamd.com asn.rspamd.com asn6.rspamd.com bl.rspamd.com uribl.rspamd.com email.rspamd.com phishtank.rspamd.com sa-update.surbl.org"
    ALLOWED_IPS=$(dig +short $ALLOWED_DOMAINS A 2>/dev/null | grep -E '^[0-9.]+$' | sort -u)

    # Flush and repopulate the set
    nft flush set inet rspamd-egress rspamd_allowed_ips 2>/dev/null || true
    for ip in $ALLOWED_IPS; do
      nft add element inet rspamd-egress rspamd_allowed_ips { $ip } 2>/dev/null || true
    done

    echo "Resolved rspamd allowed IPs ($ALLOWED_DOMAINS): $ALLOWED_IPS"
  '';

  # Network definitions
  networks = {
    # External networks (can reach internet)
    smtp-external = {
      internal = false;
      subnet = null;
      description = "OpenSMTPd external access (ports 25, 587)";
    };

    # Filtered external networks (egress restricted via nftables, but port publishing works)
    rspamd-external = {
      internal = false;
      subnet = rspamdExternalSubnet;
      description = "Rspamd external access (filtered: DNS + rspamd.com only)";
    };
    imap-external = {
      internal = false;
      subnet = imapExternalSubnet;
      description = "Dovecot external access (filtered: inbound only, no egress)";
    };

    # Internal networks (container-to-container only, no external access)
    internal = {
      internal = true;
      subnet = null;
      description = "OpenSMTPd <-> Dovecot <-> Rspamd (milter, LMTP, spam learning)";
    };
    rspamd-redis = {
      internal = true;
      subnet = null;
      description = "Rspamd <-> Redis (Bayes/cache storage)";
    };
  };

  # List of expected network names (for cleanup)
  expectedNetworks = map (name: "mail-${name}") (lib.attrNames networks);

  # Generate network creation commands
  networkCreateCmds = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: opts:
    let
      fullName = "mail-${name}";
      internalFlag = if opts.internal then "--internal" else "";
      subnetFlag = if opts.subnet != null then "--subnet ${opts.subnet}" else "";
    in ''
      if ${pkgs.podman}/bin/podman network exists ${fullName}; then
        ${if opts.subnet != null then ''
        # Check if existing network has the correct subnet
        CURRENT_SUBNET=$(${pkgs.podman}/bin/podman network inspect ${fullName} --format '{{range .Subnets}}{{.Subnet}}{{end}}' 2>/dev/null || echo "")
        if [ "$CURRENT_SUBNET" != "${opts.subnet}" ]; then
          echo "Network ${fullName} has wrong subnet ($CURRENT_SUBNET), expected ${opts.subnet}. Recreating..."

          # Disconnect any containers using this network
          for container in $(${pkgs.podman}/bin/podman network inspect ${fullName} --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); do
            echo "Disconnecting $container from ${fullName}..."
            ${pkgs.podman}/bin/podman network disconnect ${fullName} "$container" 2>/dev/null || true
          done

          # Mark that we need to restart containers
          NEEDS_CONTAINER_RESTART=1

          # Now remove and recreate
          if ! ${pkgs.podman}/bin/podman network rm ${fullName}; then
            echo "ERROR: Could not remove network ${fullName}."
            exit 1
          fi
          ${pkgs.podman}/bin/podman network create ${internalFlag} ${subnetFlag} ${fullName}
        fi
        '' else ''
        # Network exists and no specific subnet required, nothing to do
        true
        ''}
      else
        echo "Creating network ${fullName}..."
        ${pkgs.podman}/bin/podman network create ${internalFlag} ${subnetFlag} ${fullName}
      fi
    ''
  ) networks);

  # Generate cleanup commands for old networks
  networkCleanupCmds = ''
    # List of networks we expect to exist
    EXPECTED_NETWORKS="${lib.concatStringsSep " " expectedNetworks}"

    # Find and remove any mail-* networks that aren't in our expected list
    for network in $(${pkgs.podman}/bin/podman network ls --format '{{.Name}}' | grep '^mail-'); do
      if ! echo "$EXPECTED_NETWORKS" | grep -qw "$network"; then
        echo "Removing obsolete network $network..."
        ${pkgs.podman}/bin/podman network rm "$network" 2>/dev/null || \
          echo "Warning: Could not remove $network (may still be in use)"
      fi
    done
  '';

in
{
  # Create networks before any container starts
  systemd.services.mail-network-setup = {
    description = "Create mail server podman networks";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    before = [
      "podman-opensmtpd.service"
      "podman-dovecot.service"
      "podman-rspamd.service"
      "podman-rspamd-redis.service"
    ];
    after = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Track if we need to restart containers
      NEEDS_CONTAINER_RESTART=0

      # Clean up obsolete networks first
      ${networkCleanupCmds}

      # Create current networks
      ${networkCreateCmds}

      # Restart container services if any networks were recreated
      # Container services have PartOf=mail-network-setup.service, so restarting this service restarts them
      if [ "$NEEDS_CONTAINER_RESTART" = "1" ]; then
        echo "Networks were recreated. Triggering restart of dependent container services..."
        # Schedule a restart of this service (which propagates to PartOf dependents)
        # Use --no-block to avoid deadlock since we're inside this service
        systemd-run --no-block --unit=mail-network-restart systemctl restart mail-network-setup.service
      fi
    '';
  };

  # === SMTP Rate Limiting ===
  # Limit new SMTP connections to prevent abuse (20 connections per minute per IP)
  networking.nftables.enable = true;
  networking.nftables.tables.smtp-ratelimit = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority -1; policy accept;

        # Rate limit new SMTP connections (port 25)
        tcp dport 25 ct state new meter smtp-meter { ip saddr limit rate over 20/minute } drop
      }
    '';
  };

  # === Dovecot/IMAP Egress Filtering ===
  # Block all egress from imap-external network (allows inbound port publishing only)
  networking.nftables.tables.imap-egress = {
    family = "inet";
    content = ''
      chain forward {
        type filter hook forward priority filter; policy accept;

        # Allow established/related connections (required for inbound connections to work)
        ct state established,related accept

        # Block all NEW outbound connections from imap-external subnet
        # oifname check ensures we only filter traffic going out to the world, not to other containers
        ip saddr ${imapExternalSubnet} oifname != "podman*" ct state new log prefix "imap-egress-blocked: " drop
      }
    '';
  };

  # === Rspamd Egress Filtering ===
  # Allow DNS (for RBL lookups) and rspamd.com services only
  networking.nftables.tables.rspamd-egress = {
    family = "inet";
    content = ''
      set rspamd_allowed_ips {
        type ipv4_addr
        flags interval
      }

      chain forward {
        type filter hook forward priority filter; policy accept;

        # Allow established/related connections
        ct state established,related accept

        # Rules only apply to rspamd-external subnet egressing to internet
        # oifname check ensures we only filter traffic going out to the world, not to other containers
        ip saddr ${rspamdExternalSubnet} oifname != "podman*" jump rspamd_filter
      }

      chain rspamd_filter {
        # Allow DNS (UDP/TCP 53) - required for RBL lookups
        # DNS-based services: asn.rspamd.com, bl.rspamd.com, uribl.rspamd.com, etc.
        udp dport 53 accept
        tcp dport 53 accept

        # Allow rspamd.com services:
        # - HTTP/HTTPS (80, 443): maps.rspamd.com, updates.rspamd.com
        # - Fuzzy hash (11335): fuzzy1.rspamd.com, fuzzy2.rspamd.com
        tcp dport { 80, 443, 11335 } ip daddr @rspamd_allowed_ips accept

        # Log and drop everything else
        log prefix "rspamd-egress-blocked: " drop
      }
    '';
  };

  # === Rspamd IP Resolution Service ===
  # Resolve rspamd.com IPs and populate the nftables set
  systemd.services.rspamd-egress-setup = {
    description = "Populate rspamd.com IPs for egress filtering";
    wantedBy = [ "multi-user.target" ];
    before = [ "podman-rspamd.service" ];
    after = [ "network-online.target" "nftables.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.nftables pkgs.dnsutils ];
    script = rspamdEgressScript;
  };

  # Timer to refresh rspamd.com IPs hourly (handles DNS changes)
  systemd.timers.rspamd-egress-refresh = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
  systemd.services.rspamd-egress-refresh = {
    description = "Refresh rspamd.com IPs for egress filtering";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.nftables pkgs.dnsutils ];
    script = rspamdEgressScript;
  };
}
