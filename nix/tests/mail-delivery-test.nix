# VM-based integration test for OpenSMTPd + Dovecot mail delivery
# nix/tests/mail-delivery-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "mail-delivery";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/opensmtpd.nix
      ../nixos/dovecot.nix
    ];

    # === Test Certificate Generation ===
    services.testCerts = {
      enable = true;
      domain = "localhost";
      certPath = "/data/certs";
    };

    # === OpenSMTPd Configuration ===
    services.opensmtpdContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
      serverDomain = "localhost";      # PKI/HELO domain
      emailDomain = "test.local";      # Email addresses @test.local
      localDelivery = false;           # Use LMTP to Dovecot
      enableRspamd = false;
      # Test credentials (SHA-512 hash of "testpass")
      # Just usernames - domain is added automatically
      credentials = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
        "bob" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };
    };

    # === Dovecot Configuration ===
    services.dovecotContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.dovecot-image}";

      # Same test users as OpenSMTPd (simple usernames)
      users = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
        "bob" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      enableLmtp = true;
      lmtpPort = 24;
      enableSieve = false;
    };

    # Service ordering: certs -> dovecot -> opensmtpd
    systemd.services.podman-dovecot.after = [ "generate-test-certs.service" ];
    systemd.services.podman-opensmtpd.after = [ "generate-test-certs.service" "podman-dovecot.service" ];

    # Use tmpfs for /data
    fileSystems."/data" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=256M" ];
    };

    # Disable firewall for testing
    networking.firewall.enable = false;

    # Use localhost DNS to prevent DNS lookup hangs
    networking.nameservers = [ "127.0.0.1" ];

    # Set hostname
    networking.hostName = "mail";

    # VM resources
    virtualisation = {
      memorySize = 1536;  # More memory for two containers
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

    # Create maildir for test users (Dovecot may need this pre-created)
    with subtest("Prepare mail directories"):
        mail.succeed("mkdir -p /data/mail/alice")
        mail.succeed("mkdir -p /data/mail/bob")
        mail.succeed("chown -R 5000:5000 /data/mail")

    # Wait for Dovecot container
    with subtest("Dovecot starts successfully"):
        mail.wait_for_unit("podman-dovecot.service", timeout=120)
        mail.wait_for_open_port(993, timeout=60)  # IMAPS
        mail.wait_for_open_port(24, timeout=60)   # LMTP

    # Wait for OpenSMTPd container
    with subtest("OpenSMTPd starts successfully"):
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)
        mail.wait_for_open_port(25, timeout=60)   # SMTP
        mail.wait_for_open_port(587, timeout=60)  # Submission

    # Test SMTP to LMTP delivery to Alice
    with subtest("SMTP to LMTP delivery to Alice"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to alice@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: External Email for Alice' "
            "--body 'This message was sent via SMTP and delivered via LMTP to Alice.'"
        )
        time.sleep(3)
        mail.succeed("ls /data/mail/alice/new/ | grep -v '^$'")

    # Test SMTP to LMTP delivery to Bob
    with subtest("SMTP to LMTP delivery to Bob"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to bob@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: External Email for Bob' "
            "--body 'This message was sent via SMTP and delivered via LMTP to Bob.'"
        )
        time.sleep(3)
        mail.succeed("ls /data/mail/bob/new/ | grep -v '^$'")

    # Verify Alice's message via IMAP
    with subtest("Alice can read her delivered mail via IMAP"):
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
        assert "lmtp to alice" in result.lower(), f"Alice's message content not found: {result}"

    # Test authenticated submission from Alice to Bob via port 587
    with subtest("Authenticated SMTP submission from Alice to Bob"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to bob@test.local "
            "--from alice@test.local "
            "--server localhost "
            "--port 587 "
            "--tls "
            "--tls-verify "
            "--tls-ca-path /data/certs/fullchain.pem "
            "--auth-user alice "
            "--auth-password testpass "
            "--timeout 30 "
            "--header 'Subject: Message from Alice to Bob' "
            "--body 'This message was sent via authenticated SMTP from Alice to Bob.'"
        )
        time.sleep(3)

    # Verify Bob has both messages (external + from Alice)
    with subtest("Bob has both messages in mailbox"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN bob testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH ALL'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        assert "a001 OK" in result, f"IMAP LOGIN failed for Bob: {result}"
        # Bob should have 2 messages: external email + Alice's message
        assert "* SEARCH 1 2" in result or "* SEARCH 2 1" in result, \
            f"Bob should have 2 messages: {result}"

    # Verify mailbox isolation - Alice should NOT see Bob's mail
    with subtest("Mailbox isolation - Alice cannot see Bob's mail"):
        result = mail.succeed("""
            (
                sleep 1
                echo 'a001 LOGIN alice testpass'
                sleep 1
                echo 'a002 SELECT INBOX'
                sleep 1
                echo 'a003 SEARCH SUBJECT "External Email for Bob"'
                sleep 1
                echo 'a004 LOGOUT'
                sleep 1
            ) | ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null
        """)
        assert "a001 OK" in result, f"IMAP LOGIN failed for Alice: {result}"
        # Search should return empty (just "* SEARCH" with no numbers)
        assert "* SEARCH\r" in result, f"Alice can see Bob's mail (isolation failure): {result}"

    print("Mail delivery integration test passed!")
  '';
}
