# VM-based integration test for mail server
# nix/tests/mail-server-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "mail-server-integration";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/configuration.nix
      ../nixos/networking.nix
      ../nixos/mail-server.nix
      # Note: NOT hardware-ec2.nix - VM has its own hardware config
    ];

    # === Test Overrides ===

    # Use local container images instead of ECR
    services.mailServer = {
      useEcr = false;
      images = {
        opensmtpd = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
        dovecot = "docker-archive:${self.packages.${pkgs.system}.dovecot-image}";
        rspamd = "docker-archive:${self.packages.${pkgs.system}.rspamd-image}";
      };
    };

    # Disable ACME completely
    security.acme = lib.mkForce {
      acceptTerms = true;
      defaults.email = "test@test.local";
      certs = {};
    };

    # Disable nginx (used for ACME challenges in production)
    services.nginx.enable = lib.mkForce false;

    # Disable netdata for testing
    services.netdata.enable = lib.mkForce false;

    # Use tmpfs for /data instead of EBS
    fileSystems."/data" = lib.mkForce {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=512M" ];
    };

    # Disable firewall for testing
    networking.firewall.enable = lib.mkForce false;

    # Use localhost DNS
    networking.nameservers = lib.mkForce [ "127.0.0.1" ];

    # Generate self-signed certs on boot
    systemd.services.generate-test-certs = {
      description = "Generate self-signed certificates for testing";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-opensmtpd.service" "podman-dovecot.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /data/certs /data/mail /data/rspamd
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
          -keyout /data/certs/key.pem -out /data/certs/fullchain.pem \
          -days 1 -subj "/CN=localhost"
        chmod 644 /data/certs/fullchain.pem
        chmod 640 /data/certs/key.pem
        chown -R 5000:5000 /data/mail
      '';
    };

    # Override smtpd config for testing (no rdns/fcrdns checks, localhost certs)
    environment.etc."smtpd/smtpd.conf" = lib.mkForce {
      text = ''
        # Test configuration - simplified for VM testing

        # PKI certificates
        pki localhost cert "/data/certs/fullchain.pem"
        pki localhost key "/data/certs/key.pem"

        # Tables for virtual domains and users
        table aliases file:/etc/smtpd/aliases
        table domains file:/etc/smtpd/domains
        table virtuals file:/etc/smtpd/virtuals

        # Filter for rspamd (optional in test)
        filter rspamd proc-exec "filter-rspamd"

        # Listen on all interfaces - simplified for testing
        # Port 25 - SMTP (no rdns/fcrdns checks for testing)
        listen on 0.0.0.0 port 25 tls pki localhost filter rspamd

        # Port 587 - Submission
        listen on 0.0.0.0 port 587 tls-require pki localhost auth filter rspamd

        # Actions
        action "local_mail" lmtp localhost:24 virtual <virtuals>
        action "outbound" relay

        # Matching rules
        match from any for domain <domains> action "local_mail"
        match from any auth for any action "outbound"
      '';
      mode = "0644";
    };

    # Override domains for testing
    environment.etc."smtpd/domains" = lib.mkForce {
      text = ''
        test.local
      '';
      mode = "0644";
    };

    # Override virtuals for testing
    environment.etc."smtpd/virtuals" = lib.mkForce {
      text = ''
        @test.local    vmail
      '';
      mode = "0644";
    };

    # Override aliases for testing
    environment.etc."smtpd/aliases" = lib.mkForce {
      text = ''
        postmaster: root
        abuse: root
      '';
      mode = "0644";
    };

    # Create test user for Dovecot (plain text password for testing)
    environment.etc."dovecot/users" = lib.mkForce {
      text = ''
        testuser@test.local:{PLAIN}testpass
      '';
      mode = "0600";
    };

    # Override dovecot config for testing (relaxed SSL for localhost)
    environment.etc."dovecot/dovecot.conf" = lib.mkForce {
      text = ''
        # Dovecot test configuration

        protocols = imap lmtp
        listen = *, ::

        mail_location = maildir:/data/mail/%d/%n

        # SSL/TLS - relaxed for testing
        ssl = yes
        ssl_cert = </data/certs/fullchain.pem
        ssl_key = </data/certs/key.pem
        ssl_min_protocol = TLSv1.2

        mail_uid = 5000
        mail_gid = 5000
        first_valid_uid = 5000
        first_valid_gid = 5000

        auth_mechanisms = plain login

        passdb {
          driver = passwd-file
          args = scheme=PLAIN /etc/dovecot/users
        }

        userdb {
          driver = static
          args = uid=5000 gid=5000 home=/data/mail/%d/%n
        }

        protocol imap {
          mail_max_userip_connections = 20
        }

        protocol lmtp {
          postmaster_address = postmaster@test.local
        }

        service imap-login {
          inet_listener imap {
            port = 143
          }
          inet_listener imaps {
            port = 993
            ssl = yes
          }
        }

        service lmtp {
          inet_listener lmtp {
            address = 127.0.0.1
            port = 24
          }
        }

        service auth {
          unix_listener auth-userdb {
            mode = 0600
          }
        }

        namespace inbox {
          inbox = yes
          mailbox Drafts { auto = subscribe special_use = \Drafts }
          mailbox Sent { auto = subscribe special_use = \Sent }
          mailbox Trash { auto = subscribe special_use = \Trash }
          mailbox Junk { auto = subscribe special_use = \Junk }
        }

        log_path = /dev/stderr
        info_log_path = /dev/stderr
      '';
      mode = "0644";
    };

    # VM resources
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      # Ensure podman works in VM
      podman.enable = true;
    };

    # Ensure generate-test-certs runs before containers
    systemd.services.podman-rspamd.after = [ "generate-test-certs.service" ];
    systemd.services.podman-dovecot.after = [ "generate-test-certs.service" ];
    systemd.services.podman-opensmtpd.after = [ "generate-test-certs.service" ];
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

    # Wait for all container services
    with subtest("Services start successfully"):
        mail.wait_for_unit("podman-rspamd.service", timeout=120)
        mail.wait_for_unit("podman-dovecot.service", timeout=120)
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)

    # Wait for ports to be listening
    with subtest("Ports are listening"):
        mail.wait_for_open_port(25, timeout=60)    # SMTP
        mail.wait_for_open_port(587, timeout=60)   # Submission
        mail.wait_for_open_port(993, timeout=60)   # IMAPS
        mail.wait_for_open_port(11332, timeout=60) # Rspamd proxy
        mail.wait_for_open_port(11334, timeout=60) # Rspamd web UI

    # Test Rspamd API first (simplest test)
    with subtest("Rspamd API responds"):
        mail.succeed("curl -sf http://localhost:11334/ping")

    # Test SMTP connection and mail delivery
    with subtest("SMTP accepts mail and delivers to Maildir"):
        # Send test email via swaks
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to testuser@test.local "
            "--from sender@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Test Email' "
            "--body 'This is a test message.'"
        )

        # Allow time for delivery through rspamd and lmtp
        time.sleep(3)

        # Verify mail was delivered to Maildir
        mail.succeed("ls /data/mail/test.local/testuser/new/ | grep -q .")

    # Test IMAP connectivity
    with subtest("IMAP accepts connections"):
        # Basic TLS connection test to IMAPS port
        result = mail.succeed(
            "echo -e 'a001 LOGIN testuser@test.local testpass\\na002 LIST \"\" \"*\"\\na003 LOGOUT' | "
            "timeout 10 ${pkgs.openssl}/bin/openssl s_client -connect localhost:993 -quiet 2>/dev/null || true"
        )
        # Check that we got a successful login response
        assert "a001 OK" in result or "LIST" in result, f"IMAP login failed: {result}"

    print("All integration tests passed!")
  '';
}
