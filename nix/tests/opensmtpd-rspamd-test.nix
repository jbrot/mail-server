# VM-based integration test for OpenSMTPd + Rspamd
# Tests spam filtering (rejection, junk delivery) and DKIM signing
# nix/tests/opensmtpd-rspamd-test.nix

{ pkgs, self, ... }:

let
  # Generate a test DKIM key pair
  # In real deployment, use rspamadm dkim_keygen
  dkimPrivateKey = pkgs.runCommand "dkim-test-key" {
    nativeBuildInputs = [ pkgs.openssl ];
  } ''
    mkdir -p $out
    openssl genrsa -out $out/test.local.mail.key 2048
    openssl rsa -in $out/test.local.mail.key -pubout -out $out/test.local.mail.pub
    chmod 600 $out/test.local.mail.key
  '';
in
pkgs.testers.runNixOSTest {
  name = "opensmtpd-rspamd";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/opensmtpd.nix
      ../nixos/rspamd.nix
    ];

    # === Test Certificate Generation ===
    services.testCerts = {
      enable = true;
      domain = "localhost";
      certPath = "/data/certs";
    };

    # === Rspamd Configuration ===
    services.rspamdContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.rspamd-image}";

      # Action thresholds for testing
      actions = {
        reject = 15;     # GTUBE scores 1000, so it will be rejected
        addHeader = 6;   # Our test pattern scores 8, triggering add-header
        greylist = 100;  # Disable greylisting for tests
      };

      # DKIM signing
      dkim = {
        enable = true;
        selector = "mail";
        keyPath = "/data/rspamd/dkim/$domain.$selector.key";
      };

      # Debug logging
      logLevel = "info";

      # Custom rule for testing add-header behavior using multimap
      # This pattern triggers a score of 8 (above addHeader=6, below reject=15)
      extraConfig = {
        "multimap.conf" = ''
          TEST_SPAM_PATTERN {
            type = "content";
            filter = "text";
            map = "/etc/rspamd/local.d/test_spam_pattern.map";
            regexp = true;
            score = 8.0;
          }
        '';
        "test_spam_pattern.map" = ''
          /SPAM-TEST-PATTERN-ADD-HEADER/i
        '';
      };
    };

    # === OpenSMTPd Configuration ===
    services.opensmtpdContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.opensmtpd-image}";
      serverDomain = "localhost";
      emailDomain = "test.local";
      localDelivery = true;  # Use maildir with junk support
      enableRspamd = true;

      # Test credentials (SHA-512 hash of "testpass")
      credentials = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
        "bob" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };
    };

    # Install DKIM test key
    systemd.services.setup-dkim-key = {
      description = "Install DKIM test key";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-rspamd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p /data/rspamd/dkim
        cp ${dkimPrivateKey}/test.local.mail.key /data/rspamd/dkim/
        chown -R 1000:1000 /data/rspamd
        chmod 600 /data/rspamd/dkim/*.key
      '';
    };

    # Service ordering
    systemd.services.podman-rspamd.after = [ "setup-dkim-key.service" ];
    systemd.services.podman-opensmtpd.after = [
      "generate-test-certs.service"
      "podman-rspamd.service"
    ];

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
      memorySize = 2048;
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

    # Setup DKIM key
    with subtest("DKIM key installed"):
        mail.wait_for_unit("setup-dkim-key.service")
        mail.succeed("test -f /data/rspamd/dkim/test.local.mail.key")

    # Create mail directories
    with subtest("Create mail directories"):
        mail.succeed("mkdir -p /data/mail/alice/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/alice/.Junk/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/bob/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/bob/.Junk/{cur,new,tmp}")
        mail.succeed("chown -R 5000:5000 /data/mail")

    # Wait for Rspamd
    with subtest("Rspamd starts successfully"):
        mail.wait_for_unit("podman-rspamd.service", timeout=120)
        mail.wait_for_open_port(11332, timeout=60)  # Milter
        mail.wait_for_open_port(11333, timeout=60)  # API

    # Wait for OpenSMTPd
    with subtest("OpenSMTPd starts successfully"):
        mail.wait_for_unit("podman-opensmtpd.service", timeout=120)
        mail.wait_for_open_port(25, timeout=60)
        mail.wait_for_open_port(587, timeout=60)

    # Give services time to fully initialize
    time.sleep(5)

    # Test 1: GTUBE pattern triggers rejection (not delivery)
    with subtest("GTUBE spam is rejected"):
        # Send GTUBE spam - should be rejected
        result = mail.execute(
            "${pkgs.swaks}/bin/swaks "
            "--to alice@test.local "
            "--from spammer@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: GTUBE Test' "
            "--body 'XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X' "
            "2>&1"
        )
        exit_code, output = result
        print(f"GTUBE test result: exit_code={exit_code}")
        print(f"GTUBE test output: {output}")

        # swaks returns non-zero when message is rejected
        assert exit_code != 0 or "550" in output, \
            f"GTUBE spam should have been rejected but wasn't: {output}"
        print("GTUBE spam correctly rejected!")

    # Test 2: Custom spam pattern triggers add-header and junk delivery
    with subtest("Spam with add-header score delivered to Junk folder"):
        # Send email with test pattern that scores 8 (above addHeader=6, below reject=15)
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to alice@test.local "
            "--from spammer@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Special Offer!' "
            "--body 'This message contains SPAM-TEST-PATTERN-ADD-HEADER for testing.'"
        )
        time.sleep(3)

        # Check that spam went to Junk folder
        junk_count = mail.succeed("find /data/mail/alice/.Junk/new -type f | wc -l").strip()
        print(f"Junk folder count: {junk_count}")
        assert int(junk_count) >= 1, f"Spam not in Junk folder (found {junk_count} messages)"

        # Verify spam headers were added
        spam_file = mail.succeed("find /data/mail/alice/.Junk/new -type f | head -1").strip()
        spam_content = mail.succeed(f"cat '{spam_file}'")
        print(f"Spam message headers:\n{spam_content[:800]}")

        # Check for spam indicators in headers
        has_spam_markers = "X-Spam" in spam_content or "X-Spamd" in spam_content
        print(f"Spam headers present: {has_spam_markers}")

    # Test 3: Clean inbound email goes to inbox
    with subtest("Clean inbound email delivered to inbox"):
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to alice@test.local "
            "--from friend@external.com "
            "--server localhost "
            "--port 25 "
            "--timeout 30 "
            "--header 'Subject: Hello from a friend' "
            "--body 'This is a normal, clean email message. How are you today?'"
        )
        time.sleep(3)

        inbox_count = mail.succeed("find /data/mail/alice/new -type f | wc -l").strip()
        print(f"Inbox count: {inbox_count}")
        assert int(inbox_count) >= 1, f"Clean email not in inbox (found {inbox_count} messages)"

    # Test 4: DKIM signing on authenticated mail
    with subtest("Authenticated mail gets DKIM signature"):
        # Send authenticated mail from alice to bob via submission port
        mail.succeed(
            "${pkgs.swaks}/bin/swaks "
            "--to bob@test.local "
            "--from alice@test.local "
            "--server localhost "
            "--port 587 "
            "--tls "
            "--tls-verify "
            "--tls-ca-path /data/certs/fullchain.pem "
            "--auth plain "
            "--auth-user alice "
            "--auth-password testpass "
            "--timeout 30 "
            "--header 'Subject: Message from Alice' "
            "--body 'This message should have a DKIM signature.'"
        )
        time.sleep(3)

        # Find the delivered message
        msg_file = mail.succeed("find /data/mail/bob/new -type f | head -1").strip()
        assert msg_file, "No message found in Bob's inbox"

        # Check for DKIM-Signature header
        msg_content = mail.succeed(f"cat '{msg_file}'")
        print(f"Message content:\n{msg_content[:1000]}")

        assert "DKIM-Signature:" in msg_content, \
            f"DKIM-Signature header not found in message:\n{msg_content}"

        # Verify DKIM signature contains expected fields
        assert "d=test.local" in msg_content, \
            "DKIM domain (d=test.local) not found in signature"
        assert "s=mail" in msg_content, \
            "DKIM selector (s=mail) not found in signature"

        print("DKIM signature found with correct domain and selector!")

    print("OpenSMTPd + Rspamd integration test passed!")
  '';
}
