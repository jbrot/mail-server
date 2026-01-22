# VM-based integration test for standalone OpenSMTPd
# nix/tests/opensmtpd-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "opensmtpd-standalone";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/opensmtpd.nix
    ];

    # === OpenSMTPd Configuration ===
    services.opensmtpdContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
      domain = "localhost";
      localDelivery = true;   # No Dovecot needed
      enableRspamd = false;   # No Rspamd needed
      domains = [ "test.local" ];
      aliases = {
        postmaster = "root";
        abuse = "root";
      };
    };

    # Generate self-signed certs on boot
    systemd.services.generate-test-certs = {
      description = "Generate self-signed certificates for testing";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-opensmtpd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /data/certs /data/mail
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /data/certs/key.pem -out /data/certs/fullchain.pem \
          -days 1 -subj "/CN=localhost"
        chmod 644 /data/certs/fullchain.pem
        chmod 640 /data/certs/key.pem
      '';
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

    # Create test user for mail delivery
    users.users.testuser = {
      isNormalUser = true;
      uid = 1000;
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

    # Test SMTP connection and local mail delivery
    with subtest("SMTP accepts mail and delivers to mbox"):
        # Send test email via swaks to root (which exists on the system)
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to root@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Test Email' "
            "--body 'This is a test message.'"
        )

        # Allow time for delivery
        time.sleep(2)

        # Verify mail was delivered to mbox (container's /var/mail is mounted from /data/mail)
        mail.succeed("test -f /data/mail/root")
        mail.succeed("grep -q 'Subject: Test Email' /data/mail/root")

    print("OpenSMTPd standalone test passed!")
  '';
}
