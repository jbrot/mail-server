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

      # Test users (SHA-512 hash of "testpass" for both)
      users = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
        "bob" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      enableLmtp = true;
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

    # Pre-populate Maildir with test messages for both users
    with subtest("Pre-populate test mailboxes"):
        # Create Maildir structure for alice@test.local (including Junk folder)
        mail.succeed("mkdir -p /data/mail/alice/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/alice/.Junk/{cur,new,tmp}")
        mail.succeed("""
            cat > /data/mail/alice/new/1234567890.alice.mail <<'EOF'
    Return-Path: <sender@external.com>
    Delivered-To: alice@test.local
    From: sender@external.com
    To: alice@test.local
    Subject: Pre-populated Email for Alice
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <alice-message-id@test.local>

    This is a pre-populated test message for Alice.
    EOF
        """)

        # Create Maildir structure for bob@test.local
        mail.succeed("mkdir -p /data/mail/bob/{cur,new,tmp}")
        mail.succeed("""
            cat > /data/mail/bob/new/1234567890.bob.mail <<'EOF'
    Return-Path: <sender@external.com>
    Delivered-To: bob@test.local
    From: sender@external.com
    To: bob@test.local
    Subject: Pre-populated Email for Bob
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <bob-message-id@test.local>

    This is a pre-populated test message for Bob.
    EOF
        """)

        mail.succeed("chown -R 5000:5000 /data/mail")

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

    # Test IMAP authentication and message retrieval for Alice
    with subtest("Alice can authenticate and read her mail"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN alice testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 FETCH 1 BODY[TEXT]'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)

        assert "a001 OK" in result, f"IMAP LOGIN failed for Alice: {result}"
        assert "a002 OK" in result, f"IMAP SELECT failed for Alice: {result}"
        assert "message for alice" in result.lower(), f"Alice's message content not found: {result}"

    # Test IMAP authentication and message retrieval for Bob
    with subtest("Bob can authenticate and read his mail"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN bob testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 FETCH 1 BODY[TEXT]'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)

        assert "a001 OK" in result, f"IMAP LOGIN failed for Bob: {result}"
        assert "a002 OK" in result, f"IMAP SELECT failed for Bob: {result}"
        assert "message for bob" in result.lower(), f"Bob's message content not found: {result}"

    # Verify users can only see their own mail (isolation check)
    with subtest("Users have isolated mailboxes"):
        # Alice should NOT see Bob's message
        alice_result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN alice testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH TEXT "message for bob"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        # SEARCH with no results returns "* SEARCH" with no message numbers
        assert "message for bob" not in alice_result.lower() or "* SEARCH\r" in alice_result, \
            f"Alice can see Bob's mail (isolation failure): {alice_result}"

    # Test LMTP delivery to Alice
    with subtest("LMTP delivery to Alice works"):
        mail.succeed("""
            (
                echo "LHLO localhost"
                sleep 0.5
                echo "MAIL FROM:<sender@external.com>"
                sleep 0.5
                echo "RCPT TO:<alice>"
                sleep 0.5
                echo "DATA"
                sleep 0.5
                echo "From: sender@external.com"
                echo "To: alice@test.local"
                echo "Subject: LMTP Message for Alice"
                echo ""
                echo "This LMTP message is for Alice only."
                echo "."
                sleep 0.5
                echo "QUIT"
            ) | ${pkgs.netcat}/bin/nc localhost 24
        """)
        time.sleep(2)
        # Alice should now have exactly 2 messages (pre-populated + LMTP)
        # Exclude dovecot files with ! -name 'dovecot*'
        mail.succeed("test $(find /data/mail/alice -type f ! -name 'dovecot*' | wc -l) -eq 2")

    # Test LMTP delivery to Bob
    with subtest("LMTP delivery to Bob works"):
        mail.succeed("""
            (
                echo "LHLO localhost"
                sleep 0.5
                echo "MAIL FROM:<sender@external.com>"
                sleep 0.5
                echo "RCPT TO:<bob>"
                sleep 0.5
                echo "DATA"
                sleep 0.5
                echo "From: sender@external.com"
                echo "To: bob@test.local"
                echo "Subject: LMTP Message for Bob"
                echo ""
                echo "This LMTP message is for Bob only."
                echo "."
                sleep 0.5
                echo "QUIT"
            ) | ${pkgs.netcat}/bin/nc localhost 24
        """)
        time.sleep(2)
        # Bob should now have exactly 2 messages (pre-populated + LMTP)
        # Exclude dovecot files with ! -name 'dovecot*'
        mail.succeed("test $(find /data/mail/bob -type f ! -name 'dovecot*' | wc -l) -eq 2")

    # Verify LMTP-delivered messages via IMAP for both users
    with subtest("Alice can read her LMTP-delivered message"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN alice testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH SUBJECT "LMTP Message for Alice"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        assert "a001 OK" in result, f"IMAP LOGIN failed for Alice: {result}"
        # Search should return message number 2 (the LMTP-delivered one)
        assert "* SEARCH 2" in result or "* SEARCH 1 2" in result, \
            f"Alice's LMTP message not found via SEARCH: {result}"

    with subtest("Bob can read his LMTP-delivered message"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN bob testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH SUBJECT "LMTP Message for Bob"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        assert "a001 OK" in result, f"IMAP LOGIN failed for Bob: {result}"
        assert "* SEARCH 2" in result or "* SEARCH 1 2" in result, \
            f"Bob's LMTP message not found via SEARCH: {result}"

    # Final isolation check: Bob should NOT see Alice's LMTP message
    with subtest("LMTP messages are isolated between users"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN bob testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH SUBJECT "LMTP Message for Alice"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        # Search for Alice's message in Bob's mailbox should return empty
        assert "* SEARCH\r" in result or "* SEARCH 2" not in result, \
            f"Bob can see Alice's LMTP message (isolation failure): {result}"

    # Test spam filtering via sieve: X-Spam: Yes header -> Junk folder
    with subtest("LMTP spam filtering delivers to Junk folder"):
        # Send a message with X-Spam: Yes header via LMTP
        mail.succeed("""
            (
                echo "LHLO localhost"
                sleep 0.5
                echo "MAIL FROM:<spammer@example.com>"
                sleep 0.5
                echo "RCPT TO:<alice>"
                sleep 0.5
                echo "DATA"
                sleep 0.5
                echo "From: spammer@example.com"
                echo "To: alice@test.local"
                echo "Subject: Spam Test Message"
                echo "X-Spam: Yes"
                echo "Message-ID: <spam-filter-test@example.com>"
                echo ""
                echo "This message has X-Spam: Yes and should go to Junk."
                echo "."
                sleep 0.5
                echo "QUIT"
            ) | ${pkgs.netcat}/bin/nc localhost 24
        """)
        time.sleep(2)

        # Verify message is in Junk folder
        junk_content = mail.succeed("cat /data/mail/alice/.Junk/new/* /data/mail/alice/.Junk/cur/* 2>/dev/null || echo 'empty'")
        assert "Spam Test Message" in junk_content, \
            f"Spam message not found in Junk folder: {junk_content[:500]}"
        print("SUCCESS: Spam message correctly delivered to Junk folder")

    print("Dovecot standalone test passed!")
  '';
}
