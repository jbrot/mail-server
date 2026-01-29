# Podman Network Restart Issue

## Status: RESOLVED

The issue has been fixed by disabling systemd mount namespace isolation settings.
See [The Fix](#the-fix) section below.

## Summary

Container restarts with podman's netavark bridge networking were failing to restore
port forwarding due to stale network namespace references. This affected
`systemctl restart` operations used for certificate renewal.

## Symptoms

After a container restart:
- `ss -tlnp` shows ports are listening inside the container
- Connections to `localhost:<port>` hang or fail
- Direct connections to the container IP work
- Error in logs: `Error: netavark: setns: IO error: Invalid argument (os error 22)`
- Error: `Peer netns reference is invalid`

## Root Cause Analysis

### Initial Hypothesis (Incorrect)

We initially suspected this was the known podman/netavark bug:
https://github.com/containers/podman/issues/27516

However, after extensive debugging with syscall tracing, we discovered the actual
root cause is **systemd's mount namespace isolation**.

### Actual Root Cause: Systemd Mount Namespace Isolation

When systemd security settings like `ProtectHome`, `PrivateTmp`, `ProtectKernelModules`,
or `ProtectKernelTunables` are enabled, systemd creates **separate mount namespaces**
for each `ExecStart` and `ExecStop` invocation via `unshare(CLONE_NEWNS)`.

The problem:

1. **ExecStart** runs `podman start`, which spawns `conmon` to manage the container
2. `conmon` creates a network namespace and bind-mounts it to `/run/netns/<id>`
3. This bind mount only exists in conmon's mount namespace (inherited from ExecStart)
4. **ExecStop** runs `podman stop` in a **different mount namespace**
5. `netavark` tries to `setns()` to `/run/netns/<id>` but the file is either missing
   or points to an invalid namespace (the bind mount isn't visible)
6. `setns()` fails with `EINVAL`, cleanup fails, stale iptables rules remain

### Debugging Evidence

Using audit tracing on `setns`, `unshare`, and related syscalls, we observed:

```
# ExecStart runs in mount namespace 4026532377
type=SYSCALL ... syscall=272 (unshare) ... exe="/usr/lib/systemd/systemd"
# Later, conmon creates netns bind mount visible in this namespace

# ExecStop runs in a DIFFERENT mount namespace 4026532445
type=SYSCALL ... syscall=272 (unshare) ... exe="/usr/lib/systemd/systemd"
# netavark can't see the bind mount, setns fails
type=SYSCALL ... syscall=308 (setns) ... res=-22 (EINVAL)
```

When we ran `podman stop` from conmon's mount namespace using `nsenter`, it worked:
```bash
nsenter --mount=/proc/<conmon_pid>/ns/mnt podman stop opensmtpd  # SUCCESS
```

### The Stale State Problem

When netavark's cleanup fails:

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
`Error: Peer netns reference is invalid`.

**Duplicate jump rules accumulate.** The `NETAVARK-HOSTPORT-DNAT` chain gets duplicate
jump entries for each restart.

## The Fix

Disable mount namespace isolation settings in systemd service units for podman containers:

```nix
systemd.services.podman-<container>.serviceConfig = {
  # Mount namespace isolation disabled - these settings cause systemd to create
  # separate mount namespaces for ExecStart and ExecStop, breaking netavark's
  # ability to access the container's network namespace bind mount during cleanup
  ProtectHome = false;
  PrivateTmp = false;
  ProtectKernelTunables = false;
  ProtectKernelModules = false;
};
```

With these settings disabled, ExecStart and ExecStop run in the same mount namespace
(the root mount namespace), and netavark can access the network namespace bind mount
created by conmon during container startup.

### Why This Works

The `Protect*` and `PrivateTmp` settings trigger `unshare(CLONE_NEWNS)` to create a
private mount namespace. By disabling them:

- ExecStart and ExecStop both use the root mount namespace (`mnt:[4026531841]`)
- The `/run/netns/<id>` bind mount created by conmon is visible to both
- `netavark` can successfully `setns()` and clean up networking

### Security Implications

Disabling these settings reduces isolation but is acceptable for podman services because:

- Containers already have their own namespaces for isolation
- Podman itself needs access to various system paths (`/var/lib/containers`, etc.)
- The containerized services don't have direct host filesystem access anyway

## Previous Workaround (No Longer Needed)

Before finding the fix, we used host networking as a workaround:

```nix
networking.networks = [ "host" ];
networking.publishPorts = [ ];  # Not needed with host networking
```

This avoided the netavark cleanup issue entirely but sacrificed network isolation.
**This workaround is no longer necessary.**

## Affected Services

All podman container services needed the fix:
- OpenSMTPd (ports 25, 587)
- Dovecot (ports 143, 993, 24)
- Rspamd
- Redis

## Related Information

- Tests use `networking.nameservers = [ "127.0.0.1" ];` for fast-failing DNS in VM test environments
- Dovecot supports proper reload via SIGHUP (`ExecReload` configured)
- OpenSMTPd does not support SIGHUP reload (exits on SIGHUP), so it uses full restart
- The upstream podman issue https://github.com/containers/podman/issues/27516 may describe
  a related but distinct problem
