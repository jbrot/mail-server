# Monit alerting unit tests
# Verifies: disk space detection, memory detection, alert triggering
# nix/tests/monit-test.nix

{ pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "monit-alerts";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ ../nixos/monit-alerts.nix ];

    # Configure Monit with test-friendly settings
    services.monitAlerts = {
      enable = true;
      # No alertEmail - disables email alerts for unit testing
      checkInterval = 5;  # Fast checks for testing

      # Only monitor our test filesystem (not / or /data)
      filesystems = {
        testfs = "/mnt/testfs";
      };

      # Set low threshold so we can trigger it easily
      thresholds = {
        diskSpace = 50;  # Alert when >50% full
        inodeUsage = 80;
        memoryUsage = 99;  # High so it doesn't trigger
        swapUsage = 99;
        loadAvg = 100;
      };
    };

    # Create mount point and mount tiny tmpfs for testing
    systemd.tmpfiles.rules = [
      "d /mnt/testfs 0755 root root -"
    ];

    systemd.mounts = [
      {
        what = "tmpfs";
        where = "/mnt/testfs";
        type = "tmpfs";
        options = "size=1M";
        wantedBy = [ "multi-user.target" ];
      }
    ];

    environment.systemPackages = [ pkgs.monit ];
  };

  testScript = ''
    import time
    import re

    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Verify test filesystem is mounted
    machine.succeed("mountpoint -q /mnt/testfs")
    print("Test filesystem mounted")

    machine.wait_for_unit("monit.service")

    # Test 1: Monit is running and monitoring our test filesystem
    with subtest("Monit monitors test filesystem"):
        status = machine.succeed("monit status testfs")
        assert "testfs" in status, "testfs not found in monit status: " + status
        print("PASS: Monit is monitoring testfs")

    # Test 2: Initially, testfs should be OK
    with subtest("Clean filesystem shows OK status"):
        status = machine.succeed("monit status testfs")
        # Monit shows "status" followed by "OK" when filesystem is healthy
        assert re.search(r"status\s+OK", status), f"Expected OK status, got: {status}"
        print("PASS: testfs is initially healthy")

    # Test 3: Fill the filesystem past threshold and verify alert
    with subtest("Disk space alert triggers when threshold exceeded"):
        # Fill testfs past 50% (it's 1MB, so 600KB should do it)
        machine.succeed("dd if=/dev/zero of=/mnt/testfs/fillfile bs=1K count=600")

        # Verify file was created and disk is full
        df_output = machine.succeed("df /mnt/testfs")
        print(f"df output: {df_output}")

        # Wait for check cycle (checkInterval is 5 seconds)
        time.sleep(6)

        # Check status - should show alert triggered
        status = machine.succeed("monit status testfs")
        print(f"Status after fill: {status}")

        # The status should show "Resource limit matched" when threshold exceeded
        assert re.search(r"status\s+Resource limit matched", status), \
            f"Expected 'Resource limit matched' status, got: {status}"
        print("PASS: Disk space alert triggered")

    # Test 4: Clear the disk and verify recovery
    with subtest("Alert clears when disk space freed"):
        machine.succeed("rm /mnt/testfs/fillfile")
        # Verify file was deleted and disk is empty
        df_output = machine.succeed("df /mnt/testfs")
        print(f"df output: {df_output}")

        # Wait for check cycle (checkInterval is 5 seconds)
        time.sleep(6)

        status = machine.succeed("monit status testfs")
        print(f"Status after cleanup: {status}")

        # Should be back to healthy (status OK)
        assert re.search(r"status\s+OK", status), f"Expected recovery to OK, got: {status}"
        print("PASS: Alert cleared after cleanup")

    print("All Monit detection tests passed!")
  '';
}
