# VM-based integration test for complete mail server stack
# Tests: OpenSMTPd -> Rspamd -> LMTP -> Dovecot -> IMAP
# nix/tests/mail-server-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "mail-server-integration";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/mail-server.nix
    ];

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

      # Use local container images
      useEcr = false;
      images = {
        opensmtpd = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
        dovecot = "docker-archive:${self.packages.${pkgs.system}.dovecot-image}";
        rspamd = "docker-archive:${self.packages.${pkgs.system}.rspamd-image}";
        redis = "docker-archive:${self.packages.${pkgs.system}.redis-image}";
      };

      # Disable DKIM for testing (no keys generated)
      dkim.enable = false;
    };

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

    # Disable firewall for testing
    networking.firewall.enable = false;

    # Use localhost DNS to prevent DNS lookup hangs
    networking.nameservers = [ "127.0.0.1" ];

    # Set hostname
    networking.hostName = "mail";

    # Install test utilities
    environment.systemPackages = with pkgs; [
      curl
      swaks
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

    mail.start()
    mail.wait_for_unit("multi-user.target")

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

    # Wait for Redis
    with subtest("Redis starts successfully"):
        mail.wait_for_unit("podman-rspamd-redis.service", timeout=120)
        mail.wait_for_open_port(6379, timeout=60)

    # Wait for Rspamd
    with subtest("Rspamd starts successfully"):
        mail.wait_for_unit("podman-rspamd.service", timeout=120)
        mail.wait_for_open_port(11332, timeout=60)  # Milter
        mail.wait_for_open_port(11333, timeout=60)  # Normal
        mail.wait_for_open_port(11334, timeout=60)  # Controller
        time.sleep(3)

    # Wait for Dovecot
    with subtest("Dovecot starts successfully"):
        mail.wait_for_unit("podman-dovecot.service", timeout=120)
        mail.wait_for_open_port(993, timeout=60)   # IMAPS
        mail.wait_for_open_port(143, timeout=60)   # IMAP
        mail.wait_for_open_port(24, timeout=60)    # LMTP

    # Wait for OpenSMTPd
    with subtest("OpenSMTPd starts successfully"):
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)
        mail.wait_for_open_port(25, timeout=60)    # SMTP
        mail.wait_for_open_port(587, timeout=60)   # Submission

    # Give all services time to fully initialize
    time.sleep(5)

    # Test SMTP mail delivery
    with subtest("SMTP accepts mail and delivers via LMTP"):
        # Send test email via swaks (directly to port 25, no auth needed for inbound)
        mail.succeed(
            "swaks "
            "--to testuser@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Test Email from External' "
            "--body 'This is a test message delivered through the full stack.'"
        )

        # Allow time for delivery through rspamd -> LMTP -> dovecot
        time.sleep(5)

        # Verify mail was delivered to Maildir
        result = mail.succeed("ls /data/mail/testuser/new/ 2>/dev/null || ls /data/mail/testuser/cur/ 2>/dev/null || echo 'empty'")
        assert result.strip() != "empty", "No mail found in testuser's mailbox"
        print(f"Mail delivered successfully: {result}")

    # Test full e2e spam filtering: SMTP -> rspamd -> LMTP -> Junk
    with subtest("E2E: Spam email via SMTP delivered to Junk folder"):
        # Clear Junk folder
        mail.succeed("rm -f /data/mail/testuser/.Junk/new/* /data/mail/testuser/.Junk/cur/* 2>/dev/null || true")

        # Send email with TEST_SPAM_MARKER subject via SMTP
        # This should trigger the custom rspamd rule (score=10) -> X-Spam: Yes -> sieve -> Junk
        mail.succeed(
            "swaks "
            "--to testuser@test.local "
            "--from spammer@example.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: TEST_SPAM_MARKER obvious spam' "
            "--body 'This spam message should be delivered to Junk via the full pipeline. TEST_SPAM_MARKER'"
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

    # Final status check
    with subtest("All services healthy"):
        mail.succeed("curl -sf http://localhost:11334/ping")
        # Check container status
        mail.succeed("podman ps | grep -q rspamd-redis")
        mail.succeed("podman ps | grep -q rspamd")
        mail.succeed("podman ps | grep -q dovecot")
        mail.succeed("podman ps | grep -q opensmtpd")

    print("Full mail server integration test passed!")
  '';
}
