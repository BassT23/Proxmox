# Configuration

[← Back to README](../README.md)

The main configuration is `/etc/ultimate-updater/update.conf`. The active
file is preserved during updates; compare it with
`/etc/ultimate-updater/update.conf.dist` when reviewing new options. Values
are quoted shell-style settings, but the file is configuration data and
should not contain commands.

## Checks

`WITH_HOST`, `WITH_LXC`, and `WITH_VM` select target classes. The `CHECK_*`
settings control whether running/stopped/paused guests are included in a
check. Check filters are separate from update filters:

```text
ONLY_UPDATE_CHECK
EXCLUDE_UPDATE_CHECK
```

`ONLY` takes precedence over its matching `EXCLUDE`. Filters accept VMIDs,
ranges, and configured tags; check and update selections are independent.

## Updates and lifecycle

`REBOOT_IF_NEEDED` controls reboot handling for updates, not checks. Guest
start/resume behavior is controlled separately for LXC and VM targets.
`FREEBSD_UPDATES` enables or disables the writing FreeBSD/pfSense update path;
it does not disable read-only checks. `IN_HEADLESS_MODE` selects unattended
operation.

## Snapshots and backups

`SNAPSHOT`, `KEEP_SNAPSHOTS`, `BACKUP`, `BACKUP_MODE`, `BACKUP_LXC_MP`, and
`BACKUP_STORAGE` control safety actions. Snapshot and backup are independent.
`BACKUP_STORAGE` is a Proxmox storage ID, for example `pbs`, not a filesystem
path or PBS datastore name. Leave it empty for automatic selection. An
invalid or inactive ID is rejected. See [Backup and snapshots](backup-and-snapshots.md).

## Notifications and logging

`EMAIL_USER`, `EMAIL_SENDER`, `EMAIL_DAILY_CHECK`, `EMAIL_NO_UPDATES`,
`EMAIL_ONLY_SECURITY`, and `EMAIL_ONLY_ERROR` control email behavior.
`DEBUG` enables technical diagnostics and detailed job output. Keep it false
for normal user-facing output and enable it temporarily for troubleshooting.
`LOG_FILE` and `ERROR_LOG_FILE` select the local log files.

## Extra updates and scripts

The `PIHOLE`, `IOBROKER`, `PTERODACTYL`, `OCTOPRINT`, `DOCKER_COMPOSE`, and
`UNIFI` settings control optional extra-update integrations. Set
`INCLUDE_HELPER_SCRIPTS` to use scripts under
`/etc/ultimate-updater/scripts.d/<VMID>/`. An empty `.script-only` marker runs
only the guest's scripts instead of the built-in package-manager update.

`INCLUDE_FSTRIM` and `FSTRIM_WITH_MOUNTPOINT` control optional filesystem
trimming on supported ext4 nodes. Exit tracking can run configured commands
from `/etc/ultimate-updater/exit` after success or failure.

## Web UI settings

The Web UI port and HTTPS settings live in the root-owned
`/etc/ultimate-updater/web-ui.conf`. The default port is `8765`. Use the
provided CLI setter to change it, then restart
`ultimate-updater-web.service`. See [Web UI](web-ui.md).

Related: [Checks and updates](checks-and-updates.md), [Advanced operation](advanced.md).
