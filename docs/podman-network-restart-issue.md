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

### Detailed Mechanism

When a container is stopped, netavark attempts to enter the container's network namespace
via `setns()` to tear down networking (remove veth pairs, delete DNAT rules, etc.). However,
the namespace is already gone by the time cleanup runs, so `setns()` fails with
`EINVAL (os error 22)`. This leaves stale state behind.

When the new container starts, netavark sets up fresh networking (new IP, new veth, new DNAT
rules) — but the old rules are still present. The result:

**Stale iptables DNAT rules take precedence.** The `NETAVARK-DN-*` chain ends up with
duplicate entries — the old rules pointing to the dead container's IP come first:

```
# Old (stale) — never cleaned up, evaluated first:
tcp dpt:25  DNAT to:10.89.0.2:25
tcp dpt:587 DNAT to:10.89.0.2:587

# New (correct) — appended after:
tcp dpt:25  DNAT to:10.89.0.3:25
tcp dpt:587 DNAT to:10.89.0.3:587
```

Since iptables evaluates rules top-to-bottom, traffic is DNAT'd to the old IP (`10.89.0.2`)
which no longer exists, resulting in "Connection refused" or "No route to host".

**Stale veth interfaces remain.** The old `veth0@if2` stays attached to the bridge with
`Error: Peer netns reference is invalid`, while the new container gets a new veth.

**Duplicate jump rules accumulate.** The `NETAVARK-HOSTPORT-DNAT` chain gets duplicate jump
entries — one set referencing the old container ID and one set for the new.

**Key observation:** `ss -tlnp` on the host shows ports listening (via conmon), and the new
container is running correctly on its new IP. The problem is purely in the DNAT forwarding
path — traffic never reaches the new container because stale rules intercept it first.

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

## Possible Alternative Workarounds

If host networking is not acceptable, the stale DNAT rules could potentially be flushed
before restarting the container — e.g., via an `ExecStartPre` script that removes the
netavark iptables chains for the old container. This has not been tested and may have
side effects if multiple containers share the same bridge network.

## Future Considerations

Once the upstream podman issue is resolved, we could potentially switch back to bridge networking for better isolation. Monitor:
- https://github.com/containers/podman/issues/27516
- https://github.com/containers/netavark/issues

## Related Changes

- Tests use `networking.nameservers = lib.mkForce [ "127.0.0.1" ];` for fast-failing DNS in VM test environments (no internet access)
- Dovecot supports proper reload via SIGHUP (`ExecReload` configured)
- OpenSMTPd does not support SIGHUP reload (exits on SIGHUP), so it uses full restart
