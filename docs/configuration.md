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

### Ultimate Updater target selection

`USE_INTERNAL_TARGET_SELECTION` is `false` by default. When it is disabled,
the existing Proxmox Only/Exclude tag behavior is unchanged. When enabled,
the Web UI's Check and Update tri-state rules are used instead and Proxmox
Only/Exclude tags are ignored without being changed. An empty rule means no
explicit selection; `Only` includes a target, and `Exclude` removes it. Check
and Update rules are independent. Disabling the option preserves the saved
internal rules and restores the legacy tag behavior.

## Updates and lifecycle

`REBOOT_IF_NEEDED="false"` is the default and controls reboot handling for
updates, not checks. It must be deliberately enabled by an administrator in
the Web UI; enabling it requires an explicit confirmation warning. When
enabled, only supported non-API guest updates with a fresh, successful
reboot-required result may request the existing controlled guest reboot path.
API updates never auto-reboot, and host, external, unsupported, stale, or
uncertain cases remain manual. Guest start/resume behavior is controlled
separately for LXC and VM targets.

On upgrade from an older installation whose inactive legacy default was
`REBOOT_IF_NEEDED="true"`, the installer performs one idempotent migration:
it saves the prior configuration, changes only this setting to `false`, and
writes a protected migration marker. A later administrator-selected `true` is
preserved by subsequent upgrades. New installations receive `false` directly.
`FREEBSD_UPDATES` enables or disables the writing FreeBSD/pfSense update path;
it does not disable read-only checks. `IN_HEADLESS_MODE` is the persistent
unattended policy. When it is `true`, scheduled and manually started update
jobs use non-interactive APT/dpkg handling and do not create an input channel.
When it is `false` (the default), interactive local host/LXC/SSH jobs may be
attached through the existing job channel. `-s`/`--silent` remains a
per-invocation headless override. QEMU Guest Agent updates remain
non-interactive because `qm guest exec` does not provide a guest stdin
channel.

`APT_AUTO_REPAIR_DPKG` is `false` by default. When explicitly enabled, the
updater performs a bounded, read-only `dpkg --audit` probe immediately after
the existing guest snapshot/backup gate and before an APT update. Only a
clearly non-empty audit result is eligible for one
`DEBIAN_FRONTEND=noninteractive dpkg --configure -a` repair attempt, followed
by an audit verification. APT then follows its normal update and post-update
capture path; a repair is not itself an update and cannot create a successful
result for a no-op. Repair is limited to the local host, LXC `pct`, VM SSH,
and VM QEMU Guest Agent APT paths. DNF/YUM, Pacman, APK, FreeBSD pkg,
Windows, and External-APT paths are unchanged. A failed repair stops the
target with `DPKG_REPAIR_FAILED` and does not retry APT. Guest repair runs only
after the existing snapshot/backup safety gate; the Proxmox host may not have
snapshot protection, which is reported in the job output. Enable this option
only when running package maintainer scripts is explicitly desired.

## Snapshots and backups

`SNAPSHOT`, `KEEP_SNAPSHOTS`, `BACKUP`, `BACKUP_MODE`, `BACKUP_LXC_MP`, and
`BACKUP_STORAGE` control safety actions. Snapshot and backup are independent.
`BACKUP_STORAGE` is a Proxmox storage ID, for example `pbs`, not a filesystem
path or PBS datastore name. Leave it empty for automatic selection. An
invalid or inactive ID is rejected. See [Backup and snapshots](backup-and-snapshots.md).

## Notifications and logging

`EMAIL_USER`, `EMAIL_SENDER`, `EMAIL_DAILY_CHECK`, `EMAIL_SINGLE_RUNS`, `EMAIL_NO_UPDATES`,
`EMAIL_ONLY_SECURITY`, and `EMAIL_ONLY_ERROR` control email behavior.
`EMAIL_SINGLE_RUNS` is false by default; when enabled, explicitly selected
single-target jobs may send a summary limited to that job's target.
`EMAIL_DAILY_CHECK` is true by default and enables email notifications for
scheduled checks. In the Web UI this is **Email for scheduled checks**. Manual
global runs and update notifications are unaffected.
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
