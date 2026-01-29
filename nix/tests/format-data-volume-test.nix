# Test for format-data-volume service
# Verifies: formats unformatted disks, skips already-formatted disks
# nix/tests/format-data-volume-test.nix

{ pkgs, ... }:

pkgs.testers.runNixOSTest {
  name = "format-data-volume";

  nodes.machine = { config, pkgs, lib, ... }: {
    imports = [ ../nixos/format-data-volume.nix ];

    # Add a second empty disk to simulate EBS data volume
    virtualisation.emptyDiskImages = [ 64 ];  # 64MB test disk

    # Enable the service with explicit device list (VM uses /dev/vdb)
    services.formatDataVolume = {
      enable = true;
      devices = [ "/dev/vdb" ];
    };

    # Mount point for testing
    fileSystems."/data" = {
      device = "/dev/disk/by-label/data";
      fsType = "ext4";
      options = [ "nofail" ];  # Don't fail boot if not present initially
    };

    # Ensure mount point exists
    systemd.tmpfiles.rules = [ "d /data 0755 root root -" ];

    environment.systemPackages = [ pkgs.e2fsprogs pkgs.util-linux ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Test 1: Service should have formatted the empty disk
    with subtest("Formats unformatted disk"):
        machine.succeed("test -b /dev/vdb")
        fstype = machine.succeed("blkid -o value -s TYPE /dev/vdb").strip()
        assert fstype == "ext4", f"Expected ext4, got: {fstype}"
        label = machine.succeed("blkid -o value -s LABEL /dev/vdb").strip()
        assert label == "data", f"Expected label 'data', got: {label}"
        print("PASS: Unformatted disk was formatted with ext4 and labeled 'data'")

    # Test 2: Running again should NOT reformat (check by verifying UUID stays same)
    with subtest("Skips already-formatted disk"):
        uuid_before = machine.succeed("blkid -o value -s UUID /dev/vdb").strip()

        # Restart the service
        machine.succeed("systemctl restart format-data-volume.service")

        uuid_after = machine.succeed("blkid -o value -s UUID /dev/vdb").strip()
        assert uuid_before == uuid_after, f"UUID changed! Before: {uuid_before}, After: {uuid_after}"
        print(f"PASS: Disk UUID unchanged ({uuid_before}), format was skipped")

    # Test 3: Verify mount works
    with subtest("Disk can be mounted"):
        machine.succeed("mkdir -p /data")
        machine.succeed("mount /dev/disk/by-label/data /data")
        machine.succeed("touch /data/testfile")
        machine.succeed("test -f /data/testfile")
        print("PASS: Disk mounted and writable")

    print("All format-data-volume tests passed!")
  '';
}
