# Configuration

The configuration file is at `/etc/ultimate-updater/update.conf`.

You can edit it directly, or use the interactive wizard:

```bash
update --config
```

The wizard prompts for each setting. Press Enter to keep the current value.

---

## Settings reference

### General

| Setting | Default | Description |
|---|---|---|
| `USED_BRANCH` | `master` | Branch to track: `master`, `beta`, or `develop` |
| `DEBUG` | `false` | Enable `set -x` debug output |
| `LOG_FILE` | `/var/log/ultimate-updater.log` | Path to the main log file |
| `ERROR_LOG_FILE` | `/var/log/ultimate-updater-error.log` | Path to the error log |
| `VERSION_CHECK` | `true` | Check for a newer version of the updater on startup |
| `SSH_PORT` | `22` | SSH port used to reach other cluster nodes |
| `EXE_FOR_INTERNET_CHECK` | `ping` | Connectivity check tool: `ping` or `curl` |
| `URL_FOR_INTERNET_CHECK` | `google.com` | URL used for connectivity check |

### What to update

| Setting | Default | Description |
|---|---|---|
| `WITH_HOST` | `true` | Update the Proxmox host itself |
| `WITH_LXC` | `true` | Update LXC containers |
| `WITH_VM` | `true` | Update VMs |
| `STOPPED_CONTAINER` | `true` | Start stopped containers to update them, then stop again |
| `RUNNING_CONTAINER` | `true` | Update containers that are already running |
| `STOPPED_VM` | `true` | Start stopped VMs to update them |
| `RUNNING_VM` | `true` | Update VMs that are already running |
| `LXC_START_DELAY` | `5` | Seconds to wait after starting a stopped LXC |
| `VM_START_DELAY` | `45` | Seconds to wait for QEMU agent after VM start |
| `REEBOOT_IF_NEEDED` | `false` | Reboot after update if `/var/run/reboot-required` exists |
| `FREEBSD_UPDATES` | `false` | Update FreeBSD VMs |
| `INCLUDE_PHASED_UPDATES` | `false` | Include APT phased updates (Ubuntu/Debian staged rollouts) |
| `INCLUDE_FSTRIM` | `false` | Run `fstrim` on LXC containers after update |
| `FSTRIM_WITH_MOUNTPOINT` | `true` | Include mount points when running `fstrim` |
| `PACMAN_ENVIRONMENT` | _(empty)_ | Environment prefix for `pacman` (e.g. proxy settings) |
| `EXIT_ON_ERROR` | `false` | Stop the entire run immediately on the first error |

### Notifications

| Setting | Default | Description |
|---|---|---|
| `EMAIL_USER` | `root` | Email address to send update summaries to |
| `EMAIL_NO_UPDATES` | `false` | Send email even when there are no updates |
| `EMAIL_ONLY_SECURITY` | `false` | Send email only when security updates are available |

### Filtering

Use `ONLY` to restrict updates to a subset, or `EXCLUDE` to skip some.

Both accept Proxmox tags, VM/CT IDs, ID ranges, or combinations.

| Setting | Default | Description |
|---|---|---|
| `ONLY` | _(empty)_ | Only update matching containers/VMs |
| `EXCLUDE` | _(empty)_ | Skip matching containers/VMs |

If `ONLY` is set, `EXCLUDE` is ignored.

**Examples:**

```bash
# Only update containers/VMs tagged "production"
ONLY="production"

# Only update specific IDs and a range
ONLY="101,105,200-210"

# Skip containers/VMs tagged "testing" or in a range
EXCLUDE="testing,300-305"
```

### Snapshot / Backup

| Setting | Default | Description |
|---|---|---|
| `SNAPSHOT` | `true` | Create a snapshot before each update |
| `KEEP_SNAPSHOTS` | `3` | Number of update snapshots to keep per container/VM |
| `BACKUP` | `false` | Create a full backup before each update |
| `BACKUP_LXC_MP` | `true` | If snapshot fails due to mount points, fall back to backup |
| `BACKUP_MODE` | `stop` | Backup mode: `stop`, `suspend`, or `snapshot` |

**Backup mode notes:**

- `stop` — highest consistency, causes downtime, not compatible with HA
- `suspend` — good consistency, minimal downtime, compatible with HA
- `snapshot` — live backup, no downtime, requires supported storage (ZFS, LVM-Thin, Ceph)

### Extra updates (plugins)

| Setting | Default | Description |
|---|---|---|
| `EXTRA_GLOBAL` | `true` | Enable all plugins |
| `IN_HEADLESS_MODE` | `false` | Run plugins in silent/headless mode |
| `PIHOLE` | `true` | Enable Pi-hole plugin |
| `IOBROKER` | `true` | Enable ioBroker plugin |
| `PTERODACTYL` | `true` | Enable Pterodactyl plugin |
| `OCTOPRINT` | `true` | Enable OctoPrint plugin |
| `UNIFI` | `true` | Enable Unifi plugin |
| `DOCKER_COMPOSE` | `true` | Enable Docker Compose plugin |
| `COMPOSE_PATH` | `/home` | Directory to search for compose files |
| `DOCKER_PRUNE` | `false` | Run `docker system prune -a -f --volumes` after Docker updates |

**Warning about `DOCKER_PRUNE`:** Setting this to `true` permanently removes ALL unused Docker images, containers, networks, and volumes on the system — including those that are unrelated to the projects that were just updated. Only enable this if you fully understand and accept the consequence.

### Update checker (welcome screen)

| Setting | Default | Description |
|---|---|---|
| `CHECK_WITH_HOST` | `true` | Include host in update check |
| `CHECK_WITH_LXC` | `true` | Include LXC containers in update check |
| `CHECK_WITH_VM` | `true` | Include VMs in update check |
| `CHECK_STOPPED_CONTAINER` | `true` | Check stopped containers |
| `CHECK_RUNNING_CONTAINER` | `true` | Check running containers |
| `CHECK_STOPPED_VM` | `true` | Check stopped VMs |
| `CHECK_PAUSED_VM` | `true` | Check paused VMs |
| `CHECK_RUNNING_VM` | `true` | Check running VMs |
| `ONLY_UPDATE_CHECK` | _(empty)_ | Restrict update checker to matching IDs/tags |
| `EXCLUDE_UPDATE_CHECK` | _(empty)_ | Skip matching IDs/tags in update checker |
