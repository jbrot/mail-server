# VM-based integration test for standalone OpenSMTPd
# nix/tests/opensmtpd-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "opensmtpd-standalone";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/opensmtpd.nix
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
      image = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.opensmtpd-image}";
      serverDomain = "localhost";      # PKI/HELO domain
      emailDomain = "test.local";      # Email addresses @test.local
      localDelivery = true;            # Use maildir delivery (no Dovecot needed)
      enableRspamd = false;
      # Test credentials (SHA-512 hash of "testpass")
      # Just usernames - domain is added automatically
      credentials = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
        "bob" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      # Test aliases
      aliases = {
        "postmaster" = "alice";
        "info" = "bob";
        "" = "alice";  # Catchall
      };

      # Use host network to avoid netavark bridge restart issues
      # See: https://github.com/containers/podman/issues/27516
      networking.networks = [ "host" ];
      networking.publishPorts = [ ];  # Not needed with host networking
    };

    # Ensure certs are ready before container
    systemd.services.podman-opensmtpd.after = [ "generate-test-certs.service" ];

    # Use tmpfs for /data
    fileSystems."/data" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=256M" ];
    };

    # Disable firewall for testing
    networking.firewall.enable = false;

    # Fast-failing DNS (no internet in VM tests)
    networking.nameservers = lib.mkForce [ "127.0.0.1" ];

    # Set hostname
    networking.hostName = "mail";

    # VM resources
    virtualisation = {
      memorySize = 1024;
      cores = 2;
      diskSize = 4096;  # Larger disk for container images
      podman.enable = true;
    };

    # Packages needed for tests
    environment.systemPackages = [ pkgs.openssl ];
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

    # Wait for OpenSMTPd container
    with subtest("OpenSMTPd starts successfully"):
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)

    # Wait for SMTP port to be listening
    with subtest("SMTP port is listening"):
        mail.wait_for_open_port(25, timeout=60)
        mail.wait_for_open_port(587, timeout=60)

    # Test SMTP delivery to Alice
    with subtest("SMTP delivers mail to Alice"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to alice@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Email for Alice' "
            "--body 'This is a test message for Alice.'"
        )
        time.sleep(2)
        # Maildir stores messages in new/ directory
        mail.succeed("ls /data/mail/alice/new/ | grep -v '^$'")
        mail.succeed("grep -r 'Subject: Email for Alice' /data/mail/alice/")

    # Test SMTP delivery to Bob
    with subtest("SMTP delivers mail to Bob"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to bob@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Email for Bob' "
            "--body 'This is a test message for Bob.'"
        )
        time.sleep(2)
        mail.succeed("ls /data/mail/bob/new/ | grep -v '^$'")
        mail.succeed("grep -r 'Subject: Email for Bob' /data/mail/bob/")

    # Test authenticated submission from Alice to Bob
    with subtest("Authenticated submission from Alice to Bob"):
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
            "--header 'Subject: Message from Alice' "
            "--body 'This was sent via authenticated submission from Alice.'"
        )
        time.sleep(2)
        mail.succeed("grep -r 'Subject: Message from Alice' /data/mail/bob/")

    # Test delivery via alias - postmaster@test.local -> alice
    with subtest("Alias delivery: postmaster delivers to Alice"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to postmaster@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Postmaster Alias Test' "
            "--body 'This message was sent to postmaster alias.'"
        )
        time.sleep(2)
        mail.succeed("grep -r 'Subject: Postmaster Alias Test' /data/mail/alice/")

    # Test delivery via alias - info@test.local -> bob
    with subtest("Alias delivery: info delivers to Bob"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to info@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Info Alias Test' "
            "--body 'This message was sent to info alias.'"
        )
        time.sleep(2)
        mail.succeed("grep -r 'Subject: Info Alias Test' /data/mail/bob/")

    # Test catchall - unknown@test.local -> alice
    with subtest("Catchall delivery: unknown address delivers to Alice"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to nobody@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Catchall Test' "
            "--body 'This message was sent to an unknown address.'"
        )
        time.sleep(2)
        mail.succeed("grep -r 'Subject: Catchall Test' /data/mail/alice/")

    # Verify mailbox isolation - Alice's maildir should not have Bob's mail
    with subtest("Mailbox isolation"):
        mail.fail("grep -r 'Email for Bob' /data/mail/alice/")
        mail.fail("grep -r 'Email for Alice' /data/mail/bob/")

    # Test: Certificate reload
    with subtest("Certificate reload updates TLS cert"):
        # Get initial cert fingerprint
        initial_fp = mail.succeed(
            "openssl x509 -noout -fingerprint -sha256 -in /data/certs/fullchain.pem | cut -d= -f2"
        ).strip()

        # Verify SMTP is serving this cert
        smtp_fp = mail.succeed(
            "openssl s_client -connect localhost:587 -starttls smtp </dev/null 2>/dev/null | "
            "sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | "
            "openssl x509 -noout -fingerprint -sha256 | cut -d= -f2"
        ).strip()
        assert smtp_fp == initial_fp, f"Initial cert mismatch: {smtp_fp} != {initial_fp}"

        # Generate NEW cert
        mail.succeed("""
            openssl req -x509 -newkey rsa:2048 -nodes \
              -keyout /data/certs/key.pem -out /data/certs/fullchain.pem \
              -days 1 -subj "/CN=localhost/O=RENEWED"
            chmod 644 /data/certs/fullchain.pem
            chmod 640 /data/certs/key.pem
        """)

        # Verify new cert is different
        new_fp = mail.succeed(
            "openssl x509 -noout -fingerprint -sha256 -in /data/certs/fullchain.pem | cut -d= -f2"
        ).strip()
        assert new_fp != initial_fp, "New cert should have different fingerprint"

        # Reload service (same command as ACME postRun)
        mail.succeed("systemctl try-reload-or-restart podman-opensmtpd.service")
        mail.wait_for_open_port(587, timeout=60)

        # Verify SMTP now serves NEW cert
        smtp_fp_after = mail.succeed(
            "openssl s_client -connect localhost:587 -starttls smtp </dev/null 2>/dev/null | "
            "sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' | "
            "openssl x509 -noout -fingerprint -sha256 | cut -d= -f2"
        ).strip()

        assert smtp_fp_after == new_fp, f"Cert not reloaded: {smtp_fp_after} != {new_fp}"
        print("OpenSMTPd successfully reloaded with new certificate!")

    print("OpenSMTPd standalone test passed!")
  '';
}
