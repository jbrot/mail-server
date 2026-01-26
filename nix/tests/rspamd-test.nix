# VM-based integration test for standalone Rspamd
# nix/tests/rspamd-test.nix

{ pkgs, self, ... }:

let
  # Test email with GTUBE spam pattern
  gtubeEmail = pkgs.writeText "gtube.eml" ''
    From: sender@example.com
    To: recipient@example.com
    Subject: Test spam message
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <test-spam@example.com>

    This is a test message containing the GTUBE pattern:
    XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X
  '';

  # Clean test email
  cleanEmail = pkgs.writeText "clean.eml" ''
    From: sender@example.com
    To: recipient@example.com
    Subject: Hello friend
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <test-clean@example.com>

    This is a normal, clean email message.
    How are you doing today?
  '';

  # API test email
  apiTestEmail = pkgs.writeText "api-test.eml" ''
    From: sender@example.com
    To: recipient@example.com
    Subject: API test
    Date: Mon, 1 Jan 2024 00:00:00 +0000
    Message-ID: <api-test@example.com>

    Testing the checkv2 API endpoint.
  '';
in
pkgs.testers.runNixOSTest {
  name = "rspamd-standalone";

  nodes.rspamd = { config, pkgs, lib, ... }: {
    imports = [
      ../nixos/test-network.nix
      ../nixos/rspamd.nix
    ];

    # === Rspamd Configuration ===
    services.rspamdContainer = {
      enable = true;
      image = "docker-archive:${self.packages.${pkgs.system}.rspamd-image}";
      redisImage = "docker-archive:${self.packages.${pkgs.system}.redis-image}";

      # Use default ports
      milterPort = 11332;
      normalPort = 11333;
      controllerPort = 11334;

      # Custom action thresholds for testing
      actions = {
        reject = 12;
        addHeader = 5;
        greylist = 3;
      };

      # DKIM settings
      dkim = {
        enable = true;
        selector = "test";
      };

      # Bayes settings
      bayes = {
        enable = true;
        autolearn = {
          spamThreshold = 8.0;
          hamThreshold = -1.0;
        };
      };

      # Use debug logging for tests
      logLevel = "debug";

      # Use isolated network (both rspamd and redis on same network)
      networking.networks = [ "test-net" ];
      networking.publishPorts = [ "11332:11332" "11333:11333" "11334:11334" ];
      redisNetworking.networks = [ "test-net" ];
      redisNetworking.publishPorts = [ "6379:6379" ];
    };

    # Enable test network
    services.testNetwork.enable = true;

    # Ensure network is ready before containers
    systemd.services.podman-rspamd-redis.after = [ "create-test-network.service" ];
    systemd.services.podman-rspamd.after = [ "create-test-network.service" ];

    # Use tmpfs for /data
    fileSystems."/data" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=0755" "size=256M" ];
    };

    # Disable firewall for testing
    networking.firewall.enable = false;

    # Set hostname
    networking.hostName = "rspamd";

    # Install test utilities and copy test emails
    environment.systemPackages = with pkgs; [
      curl
      rspamd  # For rspamc command
    ];

    # Make test emails available
    environment.etc."test-emails/gtube.eml".source = gtubeEmail;
    environment.etc."test-emails/clean.eml".source = cleanEmail;
    environment.etc."test-emails/api-test.eml".source = apiTestEmail;

    # VM resources
    virtualisation = {
      memorySize = 1024;
      cores = 2;
      podman.enable = true;
    };
  };

  testScript = ''
    import json
    import time

    rspamd.start()
    rspamd.wait_for_unit("multi-user.target")

    with subtest("Redis starts successfully"):
        rspamd.wait_for_unit("podman-rspamd-redis.service", timeout=120)
        rspamd.wait_for_open_port(6379, timeout=60)

    with subtest("Rspamd starts successfully"):
        rspamd.wait_for_unit("podman-rspamd.service", timeout=120)
        # Give rspamd a moment to fully initialize
        time.sleep(5)

    with subtest("All ports are listening"):
        rspamd.wait_for_open_port(11332, timeout=60)  # Milter
        rspamd.wait_for_open_port(11333, timeout=60)  # API
        rspamd.wait_for_open_port(11334, timeout=60)  # Web UI

    with subtest("REST API ping endpoint"):
        result = rspamd.succeed("curl -s http://localhost:11333/ping")
        assert "pong" in result.lower(), f"Ping response did not contain 'pong': {result}"

    with subtest("GTUBE spam detection"):
        # GTUBE is a standard test string that always triggers spam detection
        result = rspamd.succeed("rspamc -h localhost:11333 symbols /etc/test-emails/gtube.eml")
        assert "GTUBE" in result, f"GTUBE pattern not detected: {result}"

    with subtest("Clean email not flagged as GTUBE"):
        result = rspamd.succeed("rspamc -h localhost:11333 symbols /etc/test-emails/clean.eml")
        assert "GTUBE" not in result, f"Clean email incorrectly flagged with GTUBE: {result}"

    with subtest("Checkv2 API returns score"):
        result = rspamd.succeed("curl -s -X POST -T /etc/test-emails/api-test.eml http://localhost:11333/checkv2")
        # Parse JSON response
        data = json.loads(result)
        assert "score" in data, f"Response missing 'score' field: {data}"
        assert "action" in data, f"Response missing 'action' field: {data}"
        print(f"Checkv2 response: score={data['score']}, action={data['action']}")

    with subtest("Custom configuration applied - actions.conf"):
        result = rspamd.succeed("cat /etc/rspamd/local.d/actions.conf")
        assert "reject = 12" in result, f"Custom reject threshold not found: {result}"
        assert "add_header = 5" in result, f"Custom add_header threshold not found: {result}"
        assert "greylist = 3" in result, f"Custom greylist threshold not found: {result}"

    with subtest("Custom configuration applied - dkim_signing.conf"):
        result = rspamd.succeed("cat /etc/rspamd/local.d/dkim_signing.conf")
        assert 'selector = "test"' in result, f"Custom DKIM selector not found: {result}"
        assert "enabled = true" in result, f"DKIM not enabled: {result}"

    with subtest("Custom configuration applied - classifier-bayes.conf"):
        result = rspamd.succeed("cat /etc/rspamd/local.d/classifier-bayes.conf")
        assert "spam_threshold = 8" in result, f"Custom spam threshold not found: {result}"
        assert "ham_threshold = -1" in result, f"Custom ham threshold not found: {result}"
        assert 'backend = "redis"' in result, f"Redis backend not configured: {result}"

    with subtest("Redis configuration applied"):
        result = rspamd.succeed("cat /etc/rspamd/local.d/redis.conf")
        assert "servers" in result, f"Redis servers not configured: {result}"
        assert "redis:6379" in result, f"Redis server address not found: {result}"

    with subtest("Custom configuration applied - logging.inc"):
        result = rspamd.succeed("cat /etc/rspamd/local.d/logging.inc")
        assert 'level = "debug"' in result, f"Debug log level not found: {result}"

    with subtest("Data directories exist"):
        rspamd.succeed("test -d /data/rspamd")
        rspamd.succeed("test -d /data/rspamd/dkim")

    with subtest("Controller web UI responds"):
        # The controller should respond to HTTP requests
        result = rspamd.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost:11334/")
        # It might return 200 or redirect, but should not be connection refused
        assert result in ["200", "301", "302", "303", "307", "308"], f"Controller returned unexpected status: {result}"

    print("Rspamd standalone test passed!")
  '';
}
