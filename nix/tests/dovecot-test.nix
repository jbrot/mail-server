# VM-based integration test for standalone Dovecot
# nix/tests/dovecot-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "dovecot-standalone";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/dovecot.nix
    ];

    # === Test Certificate Generation ===
    services.testCerts = {
      enable = true;
      domain = "localhost";
      certPath = "/data/certs";
    };

    # === Dovecot Configuration ===
    services.dovecotContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.dovecot-image}";

      # Test user (SHA-512 hash of "testpass")
      users = {
        "testuser@test.local" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      enableLmtp = true;
      enableSieve = false;  # Keep simple for this test
    };

    # Ensure certs are generated before Dovecot starts
    systemd.services.podman-dovecot.after = [ "generate-test-certs.service" ];

    # Use tmpfs for /data
    fileSystems."/data" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=256M" ];
    };

    # Disable firewall for testing
    networking.firewall.enable = false;

    # Set hostname
    networking.hostName = "mail";

    # VM resources
    virtualisation = {
      memorySize = 1024;
      cores = 2;
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

    # Pre-populate Maildir with a test message before starting Dovecot
    with subtest("Pre-populate test mailbox"):
        # Create Maildir structure for testuser@test.local
        mail.succeed("mkdir -p /data/mail/test.local/testuser/{cur,new,tmp}")
        mail.succeed("chown -R 5000:5000 /data/mail")

        # Create a test email in the new/ directory
        mail.succeed("""
            cat > /data/mail/test.local/testuser/new/1234567890.test.mail <<'EOF'
    Return-Path: <sender@external.com>
    Delivered-To: testuser@test.local
    From: sender@external.com
    To: testuser@test.local
    Subject: Pre-populated Test Email
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <test-message-id@test.local>

    This is a pre-populated test message for Dovecot IMAP testing.
    EOF
        """)
        mail.succeed("chown 5000:5000 /data/mail/test.local/testuser/new/1234567890.test.mail")

    # Wait for Dovecot container
    with subtest("Dovecot starts successfully"):
        mail.wait_for_unit("podman-dovecot.service", timeout=120)

    # Wait for IMAP ports
    with subtest("IMAP ports are listening"):
        mail.wait_for_open_port(993, timeout=60)  # IMAPS
        mail.wait_for_open_port(143, timeout=60)  # IMAP

    # Wait for LMTP port
    with subtest("LMTP port is listening"):
        mail.wait_for_open_port(24, timeout=60)

    # Test IMAP authentication and message retrieval
    with subtest("IMAP authentication and mail retrieval"):
        # Use openssl s_client to test IMAPS login and fetch
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN testuser@test.local testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 FETCH 1 BODY[TEXT]'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)

        # Verify we got successful authentication
        assert "a001 OK" in result, f"IMAP LOGIN failed: {result}"
        # Verify we selected INBOX
        assert "a002 OK" in result, f"IMAP SELECT failed: {result}"
        # Verify we could fetch the message body
        assert "pre-populated test message" in result.lower(), f"Message content not found: {result}"

    # Test LMTP delivery
    with subtest("LMTP delivery works"):
        # Send a message via LMTP
        mail.succeed("""
            (
                echo "LHLO localhost"
                sleep 0.5
                echo "MAIL FROM:<sender@external.com>"
                sleep 0.5
                echo "RCPT TO:<testuser@test.local>"
                sleep 0.5
                echo "DATA"
                sleep 0.5
                echo "From: sender@external.com"
                echo "To: testuser@test.local"
                echo "Subject: LMTP Test Message"
                echo ""
                echo "This message was delivered via LMTP."
                echo "."
                sleep 0.5
                echo "QUIT"
            ) | ${pkgs.netcat}/bin/nc localhost 24
        """)

        # Allow time for delivery
        time.sleep(2)

        # Check that the message was delivered to Maildir
        mail.succeed("ls /data/mail/test.local/testuser/new/ | grep -v '^$' | wc -l | grep -q '[1-9]'")

    # Verify the LMTP-delivered message via IMAP
    with subtest("LMTP-delivered message readable via IMAP"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN testuser@test.local testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH SUBJECT "LMTP Test Message"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)

        assert "a001 OK" in result, f"IMAP LOGIN failed: {result}"
        # Search should return at least one message number
        assert "SEARCH" in result, f"SEARCH response missing: {result}"

    print("Dovecot standalone test passed!")
  '';
}
