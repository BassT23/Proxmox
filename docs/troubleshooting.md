# Troubleshooting

[← Back to README](../README.md)

## Web UI is not reachable

Check the service and port:

```bash
systemctl status ultimate-updater-web
journalctl -u ultimate-updater-web
```

The default port is `8765`. Confirm the configured port and firewall path.
With automatic HTTPS, a missing Proxmox certificate may cause the documented
HTTP transition fallback; explicitly required HTTPS reports an unusable
certificate as an error.

## SSH connection failed

Verify name resolution, host fingerprints, key permissions, user, port, and
the resolved Internal SSH source. A disabled override is intentionally not
used. For External systems, run the explicit setup procedure and confirm the
remote helper/sudo rule.

## QGA is not ready

From the Proxmox host, check:

```bash
qm agent <VMID> ping
qm guest exec <VMID> -- true
```

Both are needed for QGA-based package operations. If the guest is stopped or
paused, review the lifecycle settings and wait for the configured readiness
delay.

## Unsupported OS or package failure

Read the target error and job log first. Do not force a Linux package path on
FreeBSD/pfSense or an unknown RPM system. For APT, metadata may be stale on
External checks because the check does not run `apt-get update`.

## Backup storage rejected

`BACKUP_STORAGE` must be an active Proxmox Storage ID with backup content,
such as `pbs`. It is not a path or PBS datastore name. Check with
`pvesm status -content backup` and either correct the ID or leave the setting
empty for automatic selection.

## Job appears stuck or interrupted

Jobs are server-side. Inspect `ultimate-updater status`, the retained job log,
and `journalctl` for the relevant unit. A browser/SSH disconnect does not
cancel a started job; a host shutdown/reboot is reported as interrupted.

For a running job, open **Live terminal** for an interactive Update or
**Live output** for a Check/non-interactive job. Reopen or reconnect the view
if the browser was closed. After a failure, **Job failed** means the job
returned a non-zero result. The root cause is normally earlier in the live
output or in the complete retained log. Typical classes are an APT/repository
error, a connectivity failure, or a transport/QGA failure; they are not all
network errors.

If the UI reports **Stream unavailable**, check the job state first, reopen the
terminal, and inspect the complete job log. If the problem is reproducible,
inspect the Web UI service journal with `journalctl -u
ultimate-updater-web.service`.

## Need more diagnostics

Set `DEBUG="true"` temporarily, reproduce the issue, and collect only the
relevant log lines. DEBUG exposes technical transport and lifecycle details;
normal output keeps those details filtered. Remove secrets, private paths,
and credentials before sharing a report.

Related: [Configuration](configuration.md), [Notifications](notifications.md),
[Upgrading](upgrading.md).
