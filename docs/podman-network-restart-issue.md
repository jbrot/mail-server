# Podman Network Restart Issue

## Summary

Container restarts with podman's netavark bridge networking fail to restore port forwarding due to stale network namespace references. This affects `systemctl try-reload-or-restart` operations used for certificate renewal.

## Symptoms

After a container restart:
- `ss -tlnp` shows ports are listening inside the container
- Connections to `localhost:<port>` hang or fail
- Direct connections to the container IP work
- Error in logs: `Error: netavark: setns: IO error: Invalid argument (os error 22)`
- Error: `Peer netns reference is invalid`

## Root Cause

Known podman/netavark bug where DNAT rules and network namespace cleanup fail during container restarts when using bridge networking.

GitHub Issue: https://github.com/containers/podman/issues/27516

## Workaround

Use host networking (`--network=host`) instead of bridge networking for containers that need to be restarted (e.g., for certificate reloads).

In NixOS module configuration:
```nix
networking.networks = [ "host" ];
networking.publishPorts = [ ];  # Not needed with host networking
```

## Trade-offs

**Host networking advantages:**
- Container restarts work reliably
- Slightly better performance (no NAT overhead)
- Simpler debugging (ports directly on host)

**Host networking disadvantages:**
- No network isolation between containers
- Port conflicts possible if multiple containers use same ports
- Container sees all host network interfaces

## Affected Services

- OpenSMTPd (ports 25, 587)
- Dovecot (ports 143, 993, 24)

## Future Considerations

Once the upstream podman issue is resolved, we could potentially switch back to bridge networking for better isolation. Monitor:
- https://github.com/containers/podman/issues/27516
- https://github.com/containers/netavark/issues

## Related Changes

- Tests use `networking.nameservers = lib.mkForce [ "127.0.0.1" ];` for fast-failing DNS in VM test environments (no internet access)
- Dovecot supports proper reload via SIGHUP (`ExecReload` configured)
- OpenSMTPd does not support SIGHUP reload (exits on SIGHUP), so it uses full restart
