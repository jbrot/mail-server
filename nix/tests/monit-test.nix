# Monit alerting unit tests
# Verifies: disk space detection, service monitoring, restart detection
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
      checkInterval = 1;  # Very fast checks for testing

      # Only monitor our test filesystem (not / or /data)
      filesystems = {
        testfs = "/mnt/testfs";
      };

      # Monitor a test service for restart detection
      services = [ "test-service" ];

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

    # Simple test service that we can kill and restart
    systemd.services.test-service = {
      description = "Test service for Monit monitoring";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        Restart = "on-failure";
        RestartSec = "1s";
      };
    };

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

        # Wait for check cycle
        time.sleep(3)

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

        # Wait for check cycle
        time.sleep(3)

        status = machine.succeed("monit status testfs")
        print(f"Status after cleanup: {status}")

        # Should be back to healthy (status OK)
        assert re.search(r"status\s+OK", status), f"Expected recovery to OK, got: {status}"
        print("PASS: Alert cleared after cleanup")

    # Test 5: Monit monitors systemd service
    with subtest("Monit monitors systemd service"):
        machine.wait_for_unit("test-service.service")
        status = machine.succeed("monit status test-service")
        assert "test-service" in status, "test-service not found in monit status: " + status
        assert re.search(r"status\s+OK", status), f"Expected OK status, got: {status}"
        print("PASS: Monit is monitoring test-service")

    # Test 6: Detect stopped service
    with subtest("Monit detects stopped service"):
        # First, find and test the check script directly
        check_script = machine.succeed("grep -oP '(?<=with path \")[^\"]+' /etc/monitrc | grep test-service").strip()
        print(f"Check script command: {check_script}")

        # Test script while service is running (should return 0)
        exit_code, output = machine.execute(check_script)
        print(f"Script output (running): {output}, exit code: {exit_code}")
        assert exit_code == 0, f"Expected exit 0 while running, got {exit_code}"

        # Stop the service
        machine.succeed("systemctl stop test-service.service")

        # Test script while service is stopped (should return 1)
        exit_code, output = machine.execute(check_script)
        print(f"Script output (stopped): {output}, exit code: {exit_code}")
        assert exit_code != 0, f"Expected non-zero exit while stopped, got {exit_code}"

        # Wait for Monit check cycle
        time.sleep(3)

        status = machine.succeed("monit status test-service")
        print(f"Status after stop: {status}")

        # Should show status != OK (service not active)
        assert not re.search(r"status\s+OK", status), f"Expected non-OK status, got: {status}"
        print("PASS: Monit detected stopped service")

        # Restart the service
        machine.succeed("systemctl start test-service.service")
        machine.wait_for_unit("test-service.service")

    # Test 7: Detect service restart (NRestarts > 0)
    with subtest("Monit detects service restart"):
        # First, ensure NRestarts is 0
        machine.succeed("systemctl reset-failed test-service.service")
        restarts_before = machine.succeed("systemctl show test-service.service -p NRestarts --value").strip()
        print(f"NRestarts before: {restarts_before}")

        # Wait for Monit to see the healthy state
        time.sleep(3)
        status = machine.succeed("monit status test-service")
        assert re.search(r"status\s+OK", status), f"Expected OK status before kill, got: {status}"

        # Kill the service to trigger a restart
        machine.succeed("systemctl kill --signal=SIGKILL test-service.service")
        time.sleep(2)  # Wait for systemd to restart it

        # Verify service is running again
        machine.wait_for_unit("test-service.service")

        # Verify NRestarts > 0
        restarts_after = machine.succeed("systemctl show test-service.service -p NRestarts --value").strip()
        print(f"NRestarts after kill: {restarts_after}")
        assert int(restarts_after) > 0, f"Expected NRestarts > 0, got {restarts_after}"

        # Wait for Monit to detect the restart
        time.sleep(3)

        status = machine.succeed("monit status test-service")
        print(f"Status after restart: {status}")

        # Should show non-OK status because NRestarts > 0
        assert not re.search(r"status\s+OK", status), \
            f"Expected non-OK status (restart detected), got: {status}"
        print("PASS: Monit detected service restart")

    # Test 8: Clear restart counter and verify recovery
    with subtest("Service recovers after reset-failed"):
        machine.succeed("systemctl reset-failed test-service.service")

        # Verify NRestarts is now 0
        restarts = machine.succeed("systemctl show test-service.service -p NRestarts --value").strip()
        print(f"NRestarts after reset: {restarts}")
        assert restarts == "0", f"Expected NRestarts = 0 after reset, got {restarts}"

        # Wait for Monit to see the recovery
        time.sleep(3)

        status = machine.succeed("monit status test-service")
        print(f"Status after reset-failed: {status}")

        assert re.search(r"status\s+OK", status), f"Expected OK status after reset, got: {status}"
        print("PASS: Service shows OK after reset-failed")

    # Test 9: Explicit restart doesn't trigger alert
    with subtest("Explicit systemctl restart does not trigger alert"):
        # Verify NRestarts is 0 before we start
        restarts_before = machine.succeed("systemctl show test-service.service -p NRestarts --value").strip()
        assert restarts_before == "0", f"Expected NRestarts = 0 before test, got {restarts_before}"

        # Do an explicit restart (administrative action, not a crash)
        machine.succeed("systemctl restart test-service.service")
        machine.wait_for_unit("test-service.service")

        # Verify NRestarts is still 0 (explicit restart doesn't count as a crash)
        restarts_after = machine.succeed("systemctl show test-service.service -p NRestarts --value").strip()
        print(f"NRestarts after explicit restart: {restarts_after}")
        assert restarts_after == "0", f"Expected NRestarts = 0 after explicit restart, got {restarts_after}"

        # Wait for Monit check cycle
        time.sleep(3)

        # Verify Monit still shows OK
        status = machine.succeed("monit status test-service")
        print(f"Status after explicit restart: {status}")
        assert re.search(r"status\s+OK", status), f"Expected OK status after explicit restart, got: {status}"
        print("PASS: Explicit restart does not trigger alert")

    print("All Monit detection tests passed!")
  '';
}
