# VM-based integration test for Dovecot + Rspamd
# Tests spam/ham learning via IMAP sieve integration
# nix/tests/dovecot-rspamd-test.nix

{ pkgs, self, ... }:

pkgs.testers.runNixOSTest {
  name = "dovecot-rspamd";

  nodes.mail = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-certs.nix
      ../nixos/test-network.nix
      ../nixos/dovecot.nix
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
      image = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.rspamd-image}";
      redis.image = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.redis-image}";

      # Debug logging
      logLevel = "info";

      # Use isolated network
      networking.networks = [ "test-net" ];
      networking.publishPorts = [ "11333:11333" "11334:11334" ];
      redis.networking.networks = [ "test-net" ];
      redis.networking.publishPorts = [ "6379:6379" ];
    };

    # === Dovecot Configuration ===
    services.dovecotContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.stdenv.hostPlatform.system}.dovecot-image}";

      # Test credentials (SHA-512 hash of "testpass")
      users = {
        "alice" = "$6$060RjN4XgGU35LkE$IJC9LNaAeOwWRsW8h0AVqufnGlENfuKQqAWPSb0O3EXk6IvuixkqpkRij69/K6OJPut0LhlbuOvrKKzfStN.Q.";
      };

      # Disable LMTP (not needed for this test)
      enableLmtp = false;

      # Enable rspamd integration (uses imap_sieve plugin)
      rspamd.enable = true;

      # Use isolated network
      networking.networks = [ "test-net" ];
      networking.publishPorts = [ "993:993" "143:143" ];
    };

    # Enable test network
    services.testNetwork.enable = true;

    # Service ordering
    systemd.services.podman-rspamd-redis.after = [ "create-test-network.service" ];
    systemd.services.podman-rspamd.after = [ "create-test-network.service" ];
    systemd.services.podman-dovecot.after = [
      "generate-test-certs.service"
      "podman-rspamd.service"
      "create-test-network.service"
    ];

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

    # Install test utilities
    environment.systemPackages = with pkgs; [
      curl
      openssl
      rspamd  # For rspamc
    ];

    # VM resources
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;  # Larger disk for multiple container images
      podman.enable = true;
    };
  };

  testScript = ''
    import json
    import time

    def get_learned_count():
        """Get total learned message count from rspamd using JSON API"""
        result = mail.succeed("rspamc -h localhost:11334 -j stat")
        stats = json.loads(result)
        learned = stats.get("learned", 0)
        print(f"Rspamd stats: learned={learned}")
        return learned

    mail.start()
    mail.wait_for_unit("multi-user.target")

    # Wait for certificates
    with subtest("Certificates generated"):
        mail.wait_for_unit("generate-test-certs.service")
        mail.succeed("test -f /data/certs/fullchain.pem")

    # Create mail directories
    with subtest("Create mail directories"):
        mail.succeed("mkdir -p /data/mail/alice/{cur,new,tmp}")
        mail.succeed("mkdir -p /data/mail/alice/.Junk/{cur,new,tmp}")
        mail.succeed("chown -R 5000:5000 /data/mail")

    # Wait for Redis
    with subtest("Redis starts successfully"):
        mail.wait_for_unit("podman-rspamd-redis.service", timeout=120)
        mail.wait_for_open_port(6379, timeout=60)

    # Wait for Rspamd
    with subtest("Rspamd starts successfully"):
        mail.wait_for_unit("podman-rspamd.service", timeout=120)
        mail.wait_for_open_port(11333, timeout=60)
        time.sleep(3)

    # Wait for Dovecot
    with subtest("Dovecot starts successfully"):
        mail.wait_for_unit("podman-dovecot.service", timeout=120)
        mail.wait_for_open_port(993, timeout=60)
        mail.wait_for_open_port(143, timeout=60)

    # Give services time to fully initialize
    time.sleep(5)

    # Verify sieve configuration is deployed
    with subtest("Sieve configuration deployed"):
        mail.succeed("test -f /etc/dovecot/sieve/report-spam.sieve")
        mail.succeed("test -f /etc/dovecot/sieve/report-ham.sieve")
        mail.succeed("test -x /etc/dovecot/sieve/sa-learn-spam.sh")
        mail.succeed("test -x /etc/dovecot/sieve/sa-learn-ham.sh")

        # Verify shell scripts have correct rspamd host (controller port 11334)
        result = mail.succeed("cat /etc/dovecot/sieve/sa-learn-spam.sh")
        assert "rspamd:11334" in result, f"Rspamd host not found in script: {result}"

    # Verify dovecot config has imap_sieve plugin
    with subtest("Dovecot imap_sieve plugin configured"):
        result = mail.succeed("cat /etc/dovecot/dovecot.conf")
        assert "imap_sieve" in result, "imap_sieve plugin not in config"
        assert "sieve_imapsieve" in result, "sieve_imapsieve not in config"
        assert "imapsieve_mailbox1_name = Junk" in result, "Junk mailbox sieve rule not found"

    # Get initial bayes stats
    with subtest("Get initial bayes stats"):
        print("Initial bayes statistics:")
        initial_learned = get_learned_count()

    # First verify direct rspamc learning works
    with subtest("Direct rspamc learn commands work"):
        learned_before = get_learned_count()

        # Learn spam directly (message must have at least 11 tokens for bayes)
        mail.succeed("""
    cat > /tmp/direct-spam.eml << 'EOF'
    From: spammer@example.com
    To: test@test.local
    Subject: Amazing offer just for you today
    Message-ID: <direct-spam-test@example.com>

    Dear valued customer, we have an incredible special limited time offer
    available exclusively for you. Click here to claim your free prize and
    receive amazing discounts on all our premium products. This opportunity
    will not last long so act now before it expires. Best regards, Sales Team.
    EOF
        """)
        result = mail.succeed("rspamc -h localhost:11334 learn_spam /tmp/direct-spam.eml")
        print(f"Direct learn_spam result: {result}")

        # Learn ham directly (message must have at least 11 tokens for bayes)
        mail.succeed("""
    cat > /tmp/direct-ham.eml << 'EOF'
    From: friend@example.com
    To: test@test.local
    Subject: Meeting tomorrow at the office
    Message-ID: <direct-ham-test@example.com>

    Hi there, just wanted to confirm our meeting scheduled for tomorrow
    afternoon at the office. Please bring the quarterly reports and any
    other relevant documentation. Let me know if you need to reschedule
    or if there are any agenda items you would like to add. Thanks!
    EOF
        """)
        result = mail.succeed("rspamc -h localhost:11334 learn_ham /tmp/direct-ham.eml")
        print(f"Direct learn_ham result: {result}")

        time.sleep(1)

        learned_after = get_learned_count()

        assert learned_after >= learned_before + 2, \
            f"Direct learning failed: expected at least 2 new learns (before={learned_before}, after={learned_after})"
        print(f"Direct rspamc learning works! Count: {learned_before} -> {learned_after}")

    # Test: Move message to Junk triggers learn_spam via sieve
    with subtest("Moving message to Junk triggers spam learning via sieve"):
        learned_before = get_learned_count()

        # Create a test email in alice's inbox (needs 11+ tokens for bayes)
        mail.succeed("""
    cat > /data/mail/alice/new/test-sieve-spam.eml << 'EOF'
    From: sender@example.com
    To: alice@test.local
    Subject: Congratulations you have won a free vacation package
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <test-sieve-spam@example.com>

    Dear lucky winner, you have been selected to receive an all expenses paid
    vacation to an exotic tropical destination. This exclusive offer is only
    available for a limited time. Reply immediately to claim your prize and
    provide your personal details for verification. Do not miss this opportunity!
    EOF
        """)
        mail.succeed("chown 5000:5000 /data/mail/alice/new/test-sieve-spam.eml")

        # Connect via IMAP and move the message to Junk folder
        imap_result = mail.succeed("""
    echo 'a001 LOGIN alice testpass
    a002 SELECT INBOX
    a003 COPY 1 Junk
    a004 STORE 1 +FLAGS (\\Deleted)
    a005 EXPUNGE
    a006 LOGOUT' | openssl s_client -connect localhost:993 -quiet 2>&1 || true
        """)
        print(f"IMAP session output (truncated): {imap_result[:500]}")

        # Give sieve time to execute
        time.sleep(5)

        learned_after = get_learned_count()

        # Verify spam was learned via sieve
        assert learned_after > learned_before, \
            f"Sieve spam learning failed: learned count did not increase (before={learned_before}, after={learned_after})"
        print(f"SUCCESS: Sieve spam learning works! Count: {learned_before} -> {learned_after}")

    # Test: Move message from Junk to Inbox triggers learn_ham via sieve
    with subtest("Moving message from Junk to Inbox triggers ham learning via sieve"):
        learned_before = get_learned_count()

        # Create a test email in Junk (needs 11+ tokens for bayes)
        mail.succeed("""
    cat > '/data/mail/alice/.Junk/new/test-sieve-ham.eml' << 'EOF'
    From: friend@example.com
    To: alice@test.local
    Subject: Reminder about dinner plans this weekend
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <test-sieve-ham@example.com>

    Hey, just a quick reminder about our dinner plans this weekend. I was
    thinking we could try that new restaurant downtown that everyone has been
    talking about. Let me know what time works best for you and whether you
    have any dietary preferences I should keep in mind when making the reservation.
    EOF
        """)
        mail.succeed("chown 5000:5000 '/data/mail/alice/.Junk/new/test-sieve-ham.eml'")

        # Connect via IMAP and move the message from Junk to INBOX
        imap_result = mail.succeed("""
    echo 'a001 LOGIN alice testpass
    a002 SELECT Junk
    a003 COPY 1 INBOX
    a004 STORE 1 +FLAGS (\\Deleted)
    a005 EXPUNGE
    a006 LOGOUT' | openssl s_client -connect localhost:993 -quiet 2>&1 || true
        """)
        print(f"IMAP session output (truncated): {imap_result[:500]}")

        # Give sieve time to execute
        time.sleep(5)

        learned_after = get_learned_count()

        # Verify ham was learned via sieve
        assert learned_after > learned_before, \
            f"Sieve ham learning failed: learned count did not increase (before={learned_before}, after={learned_after})"
        print(f"SUCCESS: Sieve ham learning works! Count: {learned_before} -> {learned_after}")

    # Final summary
    with subtest("Final bayes statistics"):
        final_learned = get_learned_count()
        # We expect at least 4 messages learned:
        # - 1 direct spam + 1 direct ham
        # - 1 sieve spam (move to Junk) + 1 sieve ham (move from Junk)
        assert final_learned >= 4, f"Expected at least 4 messages learned, got {final_learned}"
        print(f"Final learned count: {final_learned}")

    print("Dovecot + Rspamd integration test passed!")
  '';
}
