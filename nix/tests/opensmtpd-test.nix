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
      image = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
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
    };

    # Ensure generate-test-certs runs before container
    systemd.services.podman-opensmtpd.after = [ "generate-test-certs.service" ];

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

    # Verify mailbox isolation - Alice's maildir should not have Bob's mail
    with subtest("Mailbox isolation"):
        mail.fail("grep -r 'Email for Bob' /data/mail/alice/")
        mail.fail("grep -r 'Email for Alice' /data/mail/bob/")

    print("OpenSMTPd standalone test passed!")
  '';
}
