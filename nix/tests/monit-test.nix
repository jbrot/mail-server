# Monit alerting unit tests
# Verifies: disk space detection, service monitoring, restart detection,
#           container memory monitoring, OOM kill detection
# nix/tests/monit-test.nix

{ pkgs, ... }:

let
  # Build a minimal test container image with coreutils for dd/sleep
  testContainerImage = pkgs.dockerTools.buildLayeredImage {
    name = "test-container";
    tag = "latest";
    contents = [
      pkgs.coreutils
      pkgs.bash
    ];
    config = {
      Cmd = [ "${pkgs.coreutils}/bin/sleep" "infinity" ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "monit-alerts";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ ../nixos/monit-alerts.nix ];

    # Enable podman for container tests
    virtualisation.podman.enable = true;

    # Disable panic_on_oom so OOM kills don't crash the VM
    boot.kernel.sysctl."vm.panic_on_oom" = 0;

    # Make test container image available in VM filesystem
    environment.etc."test-container-image".source = testContainerImage;

    # Configure Monit with test-friendly settings
    services.monitAlerts = {
      enable = true;
      # No alert.email - disables email alerts for unit testing
      checkInterval = 1;  # Very fast checks for testing

      # Only monitor our test filesystem (not / or /data)
      filesystems = {
        targets = { testfs = "/mnt/testfs"; };
        spaceThreshold = 50;  # Alert when >50% full
        inodeThreshold = 80;
      };

      # System thresholds set high so they don't trigger during tests
      system = {
        memoryThreshold = 99;
        swapThreshold = 99;
        loadAvgThreshold = 100;
      };

      # Monitor a test service for restart detection
      services.targets = [ "test-service" ];

      # Monitor test container for memory usage
      containers = {
        targets = [ "test-container" ];
        memoryThreshold = 1;  # Very low - any usage triggers alert
      };

      # Enable OOM kill detection with wider lookback for test reliability
      oom.enable = true;
      oom.lookbackSeconds = 10;
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

    # Load test container image for container tests
    with subtest("Load test container image"):
        machine.succeed("podman load < /etc/test-container-image")
        images = machine.succeed("podman images")
        print(f"Loaded images:\n{images}")
        assert "test-container" in images, "test-container image not loaded"
        print("PASS: Test container image loaded")

    # Test 10: Container memory monitoring (container not running)
    with subtest("Container memory check detects missing container"):
        # Find the container memory check script (extract path from the test-container-memory check line)
        check_script = machine.succeed("grep 'check program test-container-memory' /etc/monitrc | grep -oP '(?<=with path \")[^\"]+'"
        ).strip()
        print(f"Container memory check script: {check_script}")

        # Test script when container doesn't exist (should return 1)
        exit_code, output = machine.execute(check_script)
        print(f"Script output (no container): {output}, exit code: {exit_code}")
        assert exit_code == 1, f"Expected exit 1 for missing container, got {exit_code}"
        print("PASS: Container memory check detects missing container")

    # Test 11: Container memory monitoring triggers alert when threshold exceeded
    with subtest("Container memory check triggers Monit alert"):
        # Create and start a container that uses memory (dd allocates buffer)
        # Use --memory to set a limit so we can calculate percentage reliably
        machine.succeed("podman run -d --name test-container --memory=64m test-container:latest sh -c 'dd if=/dev/zero of=/dev/shm/fill bs=1M count=32 && sleep infinity'")

        # Wait for container to start and allocate memory
        time.sleep(3)

        # Verify container is running
        container_status = machine.succeed("podman ps --filter name=test-container --format '{{.Status}}'")
        print(f"Container status: {container_status}")
        assert "Up" in container_status, f"Container not running: {container_status}"

        # Check memory usage
        mem_usage = machine.succeed("podman stats --no-stream --format '{{.MemPerc}}' test-container")
        print(f"Container memory usage: {mem_usage}")

        # Test script - should return 2 (over threshold, since threshold is 1%)
        exit_code, output = machine.execute(check_script)
        print(f"Script output (running): {output}, exit code: {exit_code}")
        assert exit_code == 2, f"Expected exit 2 (over threshold), got {exit_code}"

        # Wait for Monit check cycle
        time.sleep(3)

        # Check Monit status - should show failure status (threshold exceeded)
        status = machine.succeed("monit status test-container-memory")
        print(f"Container memory Monit status: {status}")
        assert re.search(r"status\s+Status failed", status), f"Expected 'Status failed' in Monit, got: {status}"
        print("PASS: Container memory alert triggered in Monit")

        # Clean up container
        machine.succeed("podman stop test-container && podman rm test-container")

    # Test 12: OOM kill detection shows OK in Monit when no OOM kills
    with subtest("OOM check shows OK in Monit when no OOM kills"):
        # Find the OOM check script (extract path from the oom-killer check line)
        oom_script = machine.succeed("grep 'check program oom-killer' /etc/monitrc | grep -oP '(?<=with path \")[^\"]+'"
        ).strip()
        print(f"OOM check script: {oom_script}")

        # Test script with no recent OOM kills (should return 0)
        exit_code, output = machine.execute(oom_script)
        print(f"OOM script output: {output}, exit code: {exit_code}")
        assert exit_code == 0, f"Expected exit 0 (no OOM), got {exit_code}"

        # Wait for Monit check cycle
        time.sleep(3)

        # Verify Monit shows OK status
        status = machine.succeed("monit status oom-killer")
        print(f"OOM Monit status: {status}")
        assert re.search(r"status\s+OK", status), f"Expected OK status in Monit, got: {status}"
        print("PASS: OOM check shows OK in Monit when no OOM kills")

    # Test 13: OOM kill detection triggers Monit alert (transient)
    # The OOM check looks back 10 seconds (oom.lookbackSeconds), so alert is transient
    with subtest("OOM check triggers transient Monit alert when OOM kill occurs"):
        # Run a container with very limited memory that will OOM
        print("Starting memory-limited container that will OOM...")

        # Start container with 6MB limit and run a memory hog
        # dd tries to allocate a 32MB buffer which will trigger OOM
        exit_code, output = machine.execute(
            "podman run --rm --name oom-test --memory=6m test-container:latest "
            "dd if=/dev/zero of=/dev/shm/fill bs=32M count=1 2>&1 || true"
        )
        print(f"OOM container output: {output}")

        # Check kernel log for OOM message immediately - this MUST exist
        oom_log = machine.succeed("journalctl -k --since '30 seconds ago' 2>/dev/null | grep -iE 'oom|killed process|out of memory' || true")
        print(f"Kernel OOM log: {oom_log}")
        assert oom_log.strip(), "OOM kill did not occur - test requires OOM to trigger"

        # Verify the script detects the OOM (within 10 second window)
        exit_code, output = machine.execute(oom_script)
        print(f"OOM script after kill: {output}, exit code: {exit_code}")
        assert exit_code == 1, f"Expected exit 1 (OOM detected), got {exit_code}"

        # Wait for Monit check cycle to pick up the alert
        time.sleep(3)

        # Verify Monit shows failed status
        status = machine.succeed("monit status oom-killer")
        print(f"OOM Monit status after kill: {status}")
        assert re.search(r"status\s+Status failed", status), f"Expected 'Status failed' in Monit after OOM, got: {status}"
        print("PASS: OOM kill detected and Monit alert triggered")

        # Now wait for the OOM to fall outside the 10-second detection window
        print("Waiting for OOM to fall outside detection window...")
        time.sleep(11)

        # Verify the script no longer detects the OOM
        exit_code, output = machine.execute(oom_script)
        print(f"OOM script after window expires: {output}, exit code: {exit_code}")
        assert exit_code == 0, f"Expected exit 0 (OOM outside window), got {exit_code}"

        # Wait for Monit check cycle to see the recovery
        time.sleep(3)

        # Verify Monit shows OK status again
        status = machine.succeed("monit status oom-killer")
        print(f"OOM Monit status after window expires: {status}")
        assert re.search(r"status\s+OK", status), f"Expected OK status in Monit after window expires, got: {status}"
        print("PASS: OOM alert cleared after detection window expired")

    print("All Monit detection tests passed!")
  '';
}
