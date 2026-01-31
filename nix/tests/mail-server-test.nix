# VM-based integration test for complete mail server stack
# Tests: OpenSMTPd -> Rspamd -> LMTP -> Dovecot -> IMAP
# nix/tests/mail-server-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "mail-server-integration";

  # Second VM acting as "the internet" - external client for testing
  nodes.internet = { config, pkgs, ... }: {
    networking.firewall.allowedTCPPorts = [ 80 ];

    # Simple HTTP server to test connectivity
    services.nginx = {
      enable = true;
      virtualHosts.default = {
        default = true;
        locations."/".return = "200 'Hello from the internet'";
      };
    };

    # Install test utilities for sending mail and checking IMAP
    environment.systemPackages = with pkgs; [
      swaks       # For sending test emails
      openssl     # For IMAP/TLS testing
      curl        # General HTTP testing
    ];
  };

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/mail-server.nix
      ../nixos/networking.nix
      ../nixos/monit-alerts.nix
    ];

    # Override AWS-specific settings from networking.nix for VM tests
    networking.useDHCP = lib.mkForce false;

    # Explicit image paths for tests
    services.mailServer.images = {
      opensmtpd = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.opensmtpd-image}";
      dovecot = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.dovecot-image}";
      rspamd = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.rspamd-image}";
      redis = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.redis-image}";
    };

    # === Test Certificate Generation ===
    services.testCerts = {
      enable = true;
      domain = "mail.test.local";
      certPath = "/data/certs";
    };

    # === Mail Server Configuration ===
    services.mailServer = {
      enable = true;
      domain = "test.local";
      hostname = "mail.test.local";

      # Test user (SHA-512 hash of "testpass")
      users = {
        "testuser" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      aliases = {
        "postmaster" = "testuser";
        "abuse" = "testuser";
      };

      # Disable DKIM for testing (no keys generated)
      dkim.enable = false;

      # Disable DNS filters for testing (no rDNS/FCrDNS in VM environment)
      enableDnsFilters = false;
    };

    # === Monit Alerting Configuration ===
    services.monitAlerts = {
      enable = true;
      alert.email = "testuser@test.local";
      checkInterval = 5;  # Fast checks for testing

      # Only monitor our test filesystem (not / or /data)
      filesystems = {
        targets = { testfs = "/mnt/testfs"; };
        spaceThreshold = 50;  # Alert when >50% full
        inodeThreshold = 80;
      };

      # System thresholds set high so they don't trigger during tests
      system = {
        memoryThreshold = 99;
        swapThreshold = 99;
        loadAvgThreshold = 100;
      };
    };

    # Test filesystem for Monit alerting (tiny tmpfs to easily trigger alerts)
    systemd.tmpfiles.rules = [
      "d /mnt/testfs 0755 root root -"
    ];

    systemd.mounts = [
      {
        what = "tmpfs";
        where = "/mnt/testfs";
        type = "tmpfs";
        options = "size=1M";
        wantedBy = [ "multi-user.target" ];
      }
    ];

    # Add custom rspamd multimap rule for test spam detection (RBLs won't work without DNS)
    # Using same pattern as opensmtpd-rspamd-test.nix which is known to work
    services.rspamdContainer.extraConfig = {
      "multimap.conf" = ''
        TEST_SPAM_MARKER {
          type = "content";
          filter = "text";
          map = "/etc/rspamd/local.d/test_spam_pattern.map";
          regexp = true;
          score = 8.0;
        }
      '';
      "test_spam_pattern.map" = ''
        /TEST_SPAM_MARKER/i
      '';
    };

    # Enable debug logging to see rspamd verdicts
    # services.rspamdContainer.logLevel = lib.mkForce "debug";

    # Service ordering - ensure certs are ready before containers
    systemd.services.podman-rspamd-redis.after = [ "generate-test-certs.service" ];
    systemd.services.podman-rspamd.after = [ "generate-test-certs.service" ];
    systemd.services.podman-dovecot.after = [ "generate-test-certs.service" ];
    systemd.services.podman-opensmtpd.after = [ "generate-test-certs.service" ];

    # Use tmpfs for /data
    fileSystems."/data" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=512M" ];
    };

    # Use dnsmasq as local DNS server (fast-failing, no internet in VM tests)
    services.dnsmasq = {
      enable = true;
      settings = {
        no-resolv = true;
        # No upstream servers - returns SERVFAIL immediately for unknown queries
        interface = "lo";
        bind-interfaces = true;
        local = "/local/";
        domain = "local";
        expand-hosts = true;
      };
    };

    # Point host DNS to local dnsmasq
    networking.nameservers = [ "127.0.0.1" ];

    # Set hostname
    networking.hostName = "mail";

    # Install test utilities (mail sending/IMAP tools are on the internet node)
    environment.systemPackages = with pkgs; [
      curl
    ];

    # VM resources
    virtualisation = {
      memorySize = 4096;
      cores = 2;
      diskSize = 8192;  # Larger disk for all container images
      podman.enable = true;
    };
  };

  testScript = ''
    import time

    # Start both VMs
    internet.start()
    mail.start()

    internet.wait_for_unit("nginx.service")
    mail.wait_for_unit("multi-user.target")

    # Get IP addresses on the inter-VM network (eth1)
    # eth0 is QEMU's NAT (10.0.2.x), eth1 is the test network
    internet_ip = internet.succeed("ip -4 addr show eth1 | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'").strip()
    mail_ip = mail.succeed("ip -4 addr show eth1 | grep -oP '(?<=inet\\s)\\d+(\\.\\d+){3}'").strip()
    print(f"Internet VM IP (eth1): {internet_ip}")
    print(f"Mail VM IP (eth1): {mail_ip}")

    # Verify host-level connectivity between VMs
    mail.succeed(f"ping -c1 -W2 {internet_ip}")
    internet.succeed(f"ping -c1 -W2 {mail_ip}")
    print("VMs can reach each other - OK")

    # Wait for network setup
    with subtest("Network isolation setup"):
        mail.wait_for_unit("mail-network-setup.service")
        # Verify all 5 networks were created
        mail.succeed("podman network exists mail-smtp-external")
        mail.succeed("podman network exists mail-rspamd-external")
        mail.succeed("podman network exists mail-imap-external")
        mail.succeed("podman network exists mail-internal")
        mail.succeed("podman network exists mail-rspamd-redis")
        print("All 5 networks created successfully")

    # Wait for certificate generation
    with subtest("Certificates generated"):
        mail.wait_for_unit("generate-test-certs.service")
        mail.succeed("test -f /data/certs/fullchain.pem")
        mail.succeed("test -f /data/certs/key.pem")

    # Create mail directories for test user
    with subtest("Create mail directories"):
        mail.succeed("mkdir -p /data/mail/testuser/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/testuser/.Junk/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/testuser/.Sent/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/testuser/.Drafts/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/testuser/.Trash/{cur,new,tmp}")
        mail.succeed("chown -R 5000:5000 /data/mail")

    # Wait for Redis (internal service - no port exposed to host)
    with subtest("Redis starts successfully"):
        mail.wait_for_unit("podman-rspamd-redis.service", timeout=120)

    # Wait for Rspamd (internal service - no ports exposed to host)
    with subtest("Rspamd starts successfully"):
        mail.wait_for_unit("podman-rspamd.service", timeout=120)
        time.sleep(3)

    # Wait for Dovecot
    with subtest("Dovecot starts successfully"):
        mail.wait_for_unit("podman-dovecot.service", timeout=120)
        mail.wait_for_open_port(993, timeout=60)   # IMAPS
        mail.wait_for_open_port(143, timeout=60)   # IMAP

    # Wait for OpenSMTPd
    with subtest("OpenSMTPd starts successfully"):
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)
        mail.wait_for_open_port(25, timeout=60)    # SMTP
        mail.wait_for_open_port(587, timeout=60)   # Submission

    # Give all services time to fully initialize
    time.sleep(5)

    # Verify container network assignments
    with subtest("Containers have correct network assignments"):
        # Check OpenSMTPd networks
        smtp_networks = mail.succeed("podman inspect opensmtpd --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'")
        assert "mail-smtp-external" in smtp_networks, f"OpenSMTPd missing mail-smtp-external: {smtp_networks}"
        assert "mail-internal" in smtp_networks, f"OpenSMTPd missing mail-internal: {smtp_networks}"

        # Check Dovecot networks (imap-external for port publishing, internal for LMTP)
        dovecot_networks = mail.succeed("podman inspect dovecot --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'")
        assert "mail-imap-external" in dovecot_networks, f"Dovecot missing mail-imap-external: {dovecot_networks}"
        assert "mail-internal" in dovecot_networks, f"Dovecot missing mail-internal: {dovecot_networks}"

        # Check Rspamd networks
        rspamd_networks = mail.succeed("podman inspect rspamd --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'")
        assert "mail-rspamd-external" in rspamd_networks, f"Rspamd missing mail-rspamd-external: {rspamd_networks}"
        assert "mail-internal" in rspamd_networks, f"Rspamd missing mail-internal: {rspamd_networks}"
        assert "mail-rspamd-redis" in rspamd_networks, f"Rspamd missing mail-rspamd-redis: {rspamd_networks}"

        # Check Redis networks (should only be on rspamd-redis network)
        redis_networks = mail.succeed("podman inspect rspamd-redis --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'")
        assert "mail-rspamd-redis" in redis_networks, f"Redis missing mail-rspamd-redis: {redis_networks}"
        # Redis should NOT be on other networks
        assert "mail-internal" not in redis_networks, f"Redis should not be on mail-internal: {redis_networks}"
        assert "mail-smtp-external" not in redis_networks, f"Redis should not be on mail-smtp-external: {redis_networks}"

        print("All containers have correct network assignments")

    # Test network isolation
    with subtest("Network isolation enforced"):
        # Redis should only be reachable by Rspamd, not by Dovecot or OpenSMTPd
        # Use bash's /dev/tcp to test port connectivity

        # Positive test: Rspamd CAN reach Redis (verifies the command works)
        mail.succeed("podman exec rspamd timeout 2 bash -c 'echo > /dev/tcp/rspamd-redis/6379'")
        print("Rspamd can reach Redis - OK (command works)")

        # Negative test: Dovecot CANNOT reach Redis
        mail.fail("podman exec dovecot timeout 2 bash -c 'echo > /dev/tcp/rspamd-redis/6379' 2>/dev/null")
        print("Dovecot cannot reach Redis - OK (isolation working)")

        # Negative test: OpenSMTPd CANNOT reach Redis
        mail.fail("podman exec opensmtpd timeout 2 bash -c 'echo > /dev/tcp/rspamd-redis/6379' 2>/dev/null")
        print("OpenSMTPd cannot reach Redis - OK (isolation working)")

    # Test egress using the internet VM (HTTP request to port 80)
    # Uses bash's /dev/tcp to make HTTP requests without requiring curl/wget
    with subtest("OpenSMTPd can reach internet"):
        # Positive test: OpenSMTPd should be able to reach the internet VM and get response
        http_cmd = f"exec 3<>/dev/tcp/{internet_ip}/80; echo -e 'GET / HTTP/1.0\\r\\nHost: {internet_ip}\\r\\n\\r\\n' >&3; cat <&3; exec 3>&-"
        result = mail.succeed(f"podman exec opensmtpd timeout 5 bash -c \"{http_cmd}\"")
        assert "Hello from the internet" in result, f"Expected greeting not found in response: {result}"
        print("OpenSMTPd can reach internet and got expected response - OK")

    with subtest("Dovecot cannot reach internet"):
        # Dovecot is on imap-external network (for port publishing) but egress is blocked via nftables
        mail.fail(f"podman exec dovecot timeout 3 bash -c 'echo > /dev/tcp/{internet_ip}/80'")
        print("Dovecot egress blocked via nftables - OK")

    with subtest("Redis cannot reach internet"):
        # Redis is on internal network, should not reach external IPs
        mail.fail(f"podman exec rspamd-redis timeout 3 bash -c 'echo > /dev/tcp/{internet_ip}/80'")
        print("Redis egress blocked - OK")

    # Test nftables rules are correctly configured
    with subtest("nftables egress filtering configured"):
        # Verify imap-egress table blocks Dovecot egress
        imap_rules = mail.succeed("nft list table inet imap-egress")
        assert "imap-egress-blocked" in imap_rules, "imap-egress log prefix missing"
        assert "drop" in imap_rules, "drop rule missing"
        print("imap-egress rules configured correctly")

        # Verify rspamd-egress table has the filter chain with correct rules
        rspamd_rules = mail.succeed("nft list table inet rspamd-egress")
        assert "rspamd_filter" in rspamd_rules, "rspamd_filter chain missing"
        assert "dport 53 accept" in rspamd_rules, "DNS allow rule missing"
        assert "11335" in rspamd_rules, "fuzzy hash port 11335 missing"
        assert "drop" in rspamd_rules, "drop rule missing"
        print("rspamd-egress rules configured correctly")

        # Verify host-firewall table handles container->host and external->host traffic
        firewall_rules = mail.succeed("nft list table inet host-firewall")
        assert 'iifname "podman*"' in firewall_rules, "podman interface match missing"
        assert "dport 53 accept" in firewall_rules, "DNS allow rule missing"
        assert "dport 22 accept" in firewall_rules, "SSH allow rule missing"
        assert "policy drop" in firewall_rules, "default drop policy missing"
        print("host-firewall rules configured correctly")

    # Test container-to-host blocking (except DNS)
    with subtest("Containers cannot reach host services"):
        # Get the gateway IP from podman network inspect (the host's IP on the container network)
        gateway = mail.succeed("podman network inspect mail-internal --format '{{(index .Subnets 0).Gateway}}'").strip()
        print(f"Container gateway: {gateway}")

        # Note: DNS (port 53) is allowed by nftables rules - this is tested implicitly by
        # mail delivery working (containers must resolve each other via aardvark-dns)

        # Negative test: Container cannot reach host SSH (port 22)
        mail.fail(f"podman exec dovecot timeout 2 bash -c 'echo > /dev/tcp/{gateway}/22'")
        print(f"Dovecot blocked from host SSH ({gateway}:22) - OK")

    # Test SMTP mail delivery from external client (internet VM)
    with subtest("SMTP accepts mail from external client"):
        # Send test email via swaks from internet VM (simulates external sender)
        internet.succeed(
            f"swaks "
            f"--to testuser@test.local "
            f"--from sender@external.com "
            f"--server {mail_ip} "
            f"--port 25 "
            f"--timeout 30 "
            f"--header 'Subject: Test Email from External' "
            f"--body 'This is a test message delivered through the full stack.'"
        )

        # Allow time for delivery through rspamd -> LMTP -> dovecot
        time.sleep(5)

        # Verify mail was delivered to Maildir
        result = mail.succeed("ls /data/mail/testuser/new/ 2>/dev/null || ls /data/mail/testuser/cur/ 2>/dev/null || echo 'empty'")
        assert result.strip() != "empty", "No mail found in testuser's mailbox"
        print(f"Mail delivered successfully: {result}")

    # Test full e2e spam filtering from external client: SMTP -> rspamd -> LMTP -> Junk
    with subtest("E2E: Spam email from external client delivered to Junk folder"):
        # Clear Junk folder
        mail.succeed("rm -f /data/mail/testuser/.Junk/new/* /data/mail/testuser/.Junk/cur/* 2>/dev/null || true")

        # Send email with TEST_SPAM_MARKER subject via SMTP from internet VM
        # This should trigger the custom rspamd rule (score=10) -> X-Spam: Yes -> sieve -> Junk
        internet.succeed(
            f"swaks "
            f"--to testuser@test.local "
            f"--from spammer@example.com "
            f"--server {mail_ip} "
            f"--port 25 "
            f"--timeout 30 "
            f"--header 'Subject: TEST_SPAM_MARKER obvious spam' "
            f"--body 'This spam message should be delivered to Junk via the full pipeline. TEST_SPAM_MARKER'"
        )

        # Wait for delivery through the full pipeline
        time.sleep(5)

        # Verify message is in Junk folder
        junk_content = mail.succeed("cat /data/mail/testuser/.Junk/new/* /data/mail/testuser/.Junk/cur/* 2>/dev/null || echo 'empty'")
        assert "TEST_SPAM_MARKER" in junk_content, \
            f"E2E spam message not found in Junk folder. Content: {junk_content[:500]}"

        # Also verify X-Spam header was added by rspamd
        assert "X-Spam: yes" in junk_content, \
            f"X-Spam header not found in message: {junk_content[:500]}"
        print("SUCCESS: E2E spam filtering works - message delivered to Junk with X-Spam header")

    # Test IMAP accessibility from external client
    with subtest("IMAP accessible from external client"):
        # Test IMAPS (port 993) - login and list mailboxes
        # Using curl with IMAP support, -k to accept self-signed test certs
        imap_result = internet.succeed(
            f"curl -k --user testuser:testpass 'imaps://{mail_ip}/INBOX' 2>&1"
        )
        print(f"IMAP INBOX response: {imap_result[:500]}")

        # Test basic IMAP connectivity on port 143
        internet.succeed(f"timeout 5 bash -c 'echo > /dev/tcp/{mail_ip}/143'")
        print("IMAP port 143 reachable from external client")

        # Test IMAPS connectivity on port 993
        internet.succeed(f"timeout 5 bash -c 'echo > /dev/tcp/{mail_ip}/993'")
        print("IMAPS port 993 reachable from external client")

    # Test that local submission port is not accessible from external clients
    with subtest("Local submission port not accessible from internet"):
        # Port 10025 should only be bound to localhost on the mail server
        # External clients should not be able to connect
        internet.fail(f"timeout 3 bash -c 'echo > /dev/tcp/{mail_ip}/10025'")
        print("Port 10025 correctly blocked from external access")

    # Test Monit alert email delivery through the full mail stack
    with subtest("Monit alert email delivered through mail stack"):
        # Wait for Monit service to be running
        mail.wait_for_unit("monit.service")

        # Verify test filesystem is mounted
        mail.succeed("mountpoint -q /mnt/testfs")
        print("Test filesystem mounted for Monit alerting")

        # Clear any existing mail in testuser's inbox
        mail.succeed("rm -f /data/mail/testuser/new/* /data/mail/testuser/cur/* 2>/dev/null || true")

        # Fill testfs past 50% threshold (it's 1MB, so 600KB triggers alert)
        mail.succeed("dd if=/dev/zero of=/mnt/testfs/fillfile bs=1K count=600 2>/dev/null")
        print("Filled test filesystem past threshold")

        # Wait for Monit check cycle (5 seconds) plus time for email delivery
        # through the full stack: OpenSMTPd -> LMTP -> Dovecot (no rspamd on port 10025)
        time.sleep(15)

        # Check for alert email in testuser's mailbox
        mail_content = mail.succeed("cat /data/mail/testuser/new/* /data/mail/testuser/cur/* 2>/dev/null || echo 'empty'")

        # Log the full email content for debugging
        print("=" * 60)
        print("Monit alert email content:")
        print("=" * 60)
        print(mail_content)
        print("=" * 60)

        # Monit alert emails contain "monit alert" in subject and filesystem name in body
        assert "monit" in mail_content.lower(), \
            f"Monit alert email not found in mailbox. Content: {mail_content[:500]}"
        assert "testfs" in mail_content, \
            f"Alert email doesn't mention testfs. Content: {mail_content[:500]}"
        print("SUCCESS: Monit alert email delivered through full mail stack")

        # Cleanup: remove the fill file
        mail.succeed("rm -f /mnt/testfs/fillfile")

    # Test container failure alert via Monit (targeting OpenSMTPd to test event queue)
    with subtest("Container failure alert email delivered via Monit"):
        # Clear any existing mail in testuser's inbox
        mail.succeed("rm -f /data/mail/testuser/new/* /data/mail/testuser/cur/* 2>/dev/null || true")

        # Verify Monit is monitoring the container services
        monit_status = mail.succeed("monit status podman-opensmtpd")
        print(f"Monit status for opensmtpd:\n{monit_status}")

        # Kill OpenSMTPd to simulate a crash
        # This tests Monit's event queue - alert can't be sent while mail server is down
        # but should be delivered once it comes back up
        mail.succeed("systemctl kill --signal=SIGKILL podman-opensmtpd.service")
        time.sleep(2)

        # Restart OpenSMTPd
        mail.wait_for_unit("podman-opensmtpd.service", timeout=60)
        mail.wait_for_open_port(25, timeout=30)

        # Verify the service is running but has restart count > 0
        restarts = mail.succeed("systemctl show podman-opensmtpd.service -p NRestarts --value").strip()
        print(f"NRestarts counter: {restarts}")
        assert int(restarts) > 0, f"Expected NRestarts > 0, got {restarts}"

        # Wait for Monit to detect the restart and deliver queued alert
        time.sleep(15)

        # Check Monit status shows the issue
        monit_status_after = mail.succeed("monit status podman-opensmtpd || true")
        print(f"Monit status after restart:\n{monit_status_after}")

        # Check for failure alert email in testuser's mailbox
        mail_content = mail.succeed("cat /data/mail/testuser/new/* /data/mail/testuser/cur/* 2>/dev/null || echo 'empty'")

        # Log the full email content for debugging
        print("=" * 60)
        print("Container failure alert email content:")
        print("=" * 60)
        print(mail_content)
        print("=" * 60)

        # Verify the alert email mentions the failed service
        assert "podman-opensmtpd" in mail_content, \
            f"Container failure alert not found in mailbox. Content: {mail_content[:500]}"
        # Alert may say "not active" (detected while down) or "restart" (detected NRestarts > 0)
        assert "not active" in mail_content.lower() or "restart" in mail_content.lower(), \
            f"Alert email doesn't mention failure. Content: {mail_content[:500]}"
        print("SUCCESS: Container failure alert delivered via Monit (event queue worked)")

        # Clear the restart counter for subsequent tests
        mail.succeed("systemctl reset-failed podman-opensmtpd.service")
        print("Cleared NRestarts counter with reset-failed")

    # Final status check
    with subtest("All services healthy"):
        # Show all containers for diagnostics
        containers = mail.succeed("podman ps -a --format '{{.Names}} {{.Status}}'")
        print(f"Container status:\n{containers}")

        # Check container status
        assert "rspamd-redis" in mail.succeed("podman ps --format '{{.Names}}'"), "rspamd-redis not running"
        assert "rspamd" in mail.succeed("podman ps --format '{{.Names}}'"), "rspamd not running"
        assert "dovecot" in mail.succeed("podman ps --format '{{.Names}}'"), "dovecot not running"
        assert "opensmtpd" in mail.succeed("podman ps --format '{{.Names}}'"), "opensmtpd not running"
        print("All containers healthy")

    print("Full mail server integration test passed!")
  '';
}
