<div align="center">

![Logo](https://github.com/BassT23/Proxmox/assets/30832786/6400ed7f-71c6-486c-b5ed-249c2e0df19b)

[![GitHub release](https://img.shields.io/github/release/BassT23/Proxmox.svg)](https://GitHub.com/BassT23/Proxmox/releases/)
[![GitHub stars](https://img.shields.io/github/stars/BassT23/Proxmox.svg)](https://github.com/BassT23/Proxmox/stargazers)
[![downloads](https://img.shields.io/github/downloads/BassT23/Proxmox/total.svg)](https://github.com/BassT23/Proxmox/releases)
[![Discord](https://img.shields.io/discord/1149671790864506882)](https://discord.gg/nVpUg6BKn8)

</div>

# The Ultimate Updater for Proxmox VE

A single command to update your entire Proxmox environment: the host, all LXC containers, and all VMs. Supports clusters, snapshots, backups, and extra update plugins.

## Requirements

- Proxmox VE 7 or later
- Root access on the Proxmox host

---

## Installation

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

After installation, run the updater with:

```bash
update
```

---

## Usage

```
update [OPTIONS] [COMMAND]

Commands:
  host                 Update this host, all containers, and all VMs
  cluster              Update all cluster nodes
  <VMID>               Update a single container or VM by ID

  status               Show version status (local vs server)
  --config             Run the interactive configuration wizard
  uninstall            Uninstall The Ultimate Updater

Self-update:
  master  -up          Update to the latest stable release
  beta    -up          Update to the beta branch
  develop -up          Update to the develop branch

Options:
  -s, --silent         Headless mode (no interactive prompts)
  -v, --version        Show version information
  -h, --help           Show this help message
  -dist-upgrade        Run Debian distribution upgrade on all containers
  -check               Run the update checker (welcome screen data)
```

Running `update` with no arguments defaults to `host` mode.

---

## Configuration

The configuration file is located at `/etc/ultimate-updater/update.conf`.

You can edit it directly, or use the interactive wizard:

```bash
update --config
```

The wizard guides you through each setting and explains what it does.

### Key settings

| Setting | Default | Description |
|---|---|---|
| `WITH_HOST` | `true` | Update the Proxmox host itself |
| `WITH_LXC` | `true` | Update LXC containers |
| `WITH_VM` | `true` | Update VMs |
| `STOPPED_CONTAINER` | `true` | Start stopped containers to update them |
| `SNAPSHOT` | `true` | Create a snapshot before each update |
| `KEEP_SNAPSHOTS` | `3` | Number of snapshots to keep per container/VM |
| `REEBOOT_IF_NEEDED` | `false` | Reboot after update if required |
| `EXTRA_GLOBAL` | `true` | Enable extra update plugins |
| `EXIT_ON_ERROR` | `false` | Stop the entire run on the first error |

Full documentation of all settings is in the config file itself.

### Filtering — only update specific containers or VMs

Use `ONLY` to restrict updates to a subset, or `EXCLUDE` to skip some.

Both settings accept Proxmox tags, VM/CT IDs, ID ranges, or combinations:

```bash
# Only update containers/VMs tagged "production"
ONLY="production"

# Only update specific IDs and a range
ONLY="101,105,200-210"

# Skip containers/VMs tagged "testing" or in a range
EXCLUDE="testing,300-305"
```

If `ONLY` is set, `EXCLUDE` is ignored.

---

## VM updates via SSH

By default, VMs are updated through the QEMU guest agent. For richer output and SSH-based plugin support, you can configure SSH access per VM.

Create a file at `/etc/ultimate-updater/VMs/<VMID>` with the following content:

```bash
IP="192.168.1.10"
USER="root"
SSH_VM_PORT="22"
SSH_START_DELAY_TIME="45"
```

See [ssh.md](ssh.md) for setup instructions including SSH key-based authentication.

---

## Cluster mode

When Corosync is detected (`/etc/corosync/corosync.conf`), the updater switches to cluster mode automatically. Run from any node:

```bash
update
# or explicitly:
update cluster
```

The updater connects to each node via SSH and runs the update there. No extra configuration is required beyond standard SSH key access between nodes.

---

## Extra updates (plugins)

After the system packages are updated on each container or VM, the updater runs any enabled plugins found in `/etc/ultimate-updater/plugins/`.

### Built-in plugins

| Plugin file | Application | Config key |
|---|---|---|
| `pihole.sh` | Pi-hole | `PIHOLE` |
| `iobroker.sh` | ioBroker | `IOBROKER` |
| `pterodactyl.sh` | Pterodactyl Panel + Wings | `PTERODACTYL` |
| `octoprint.sh` | OctoPrint | `OCTOPRINT` |
| `docker-compose.sh` | Docker Compose projects | `DOCKER_COMPOSE` |
| `unifi.sh` | Unifi Network Controller | `UNIFI` |

Each plugin checks whether its application is actually installed before doing anything. Enabling a plugin when the application is not present is harmless.

### Docker cleanup

The Docker plugin can optionally run a full cleanup after updating images:

```bash
DOCKER_PRUNE="true"
```

**Warning:** This permanently removes all unused images, containers, networks, and volumes — including those unrelated to the updated projects. Only enable this if you understand and accept the consequence.

### Writing your own plugin

Create a `.sh` file in `/etc/ultimate-updater/plugins/`. The file is executed as a subprocess inside the container or VM being updated. Use the `CONFIG_FILE` variable to read settings:

```bash
#!/bin/bash

# Example plugin: update a custom application
MY_APP=$(awk -F'"' '/^MY_APP=/ {print $2}' "${CONFIG_FILE:-/etc/ultimate-updater/update.conf}")
[[ "${MY_APP}" == true ]] || exit 0
[[ -f /usr/local/bin/myapp ]] || exit 0

echo "--- Updating My App ---"
myapp update
```

Add a toggle key to `update.conf` if you want to control the plugin from the config file.

Plugins run in alphabetical order by filename.

---

## Welcome screen

The welcome screen shows pending updates when you SSH into the Proxmox host. It is optional and can be installed or removed at any time:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) welcome
```

The welcome screen is updated by a cron job (`/etc/crontab`) that runs `update -check` twice a day.

---

## User scripts

You can run custom scripts on specific containers or VMs after the update completes. Place your scripts in:

```
/etc/ultimate-updater/scripts.d/<VMID>/
```

Scripts are pushed into the container/VM and executed there after all updates and plugins have run. See `scripts.d/000/example.sh` for a minimal example.

---

## Updating The Ultimate Updater

```bash
update master -up    # latest stable
update beta -up      # beta branch
update develop -up   # development branch
```

Or run the installer directly:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
```

---

## Uninstall

```bash
update uninstall
```

---

## Troubleshooting

**Enable debug output:**

```bash
DEBUG="true"   # in update.conf
```

This activates `set -x` and prints every command as it runs.

**Check the log files:**

```bash
cat /var/log/ultimate-updater.log
cat /var/log/ultimate-updater-error.log
```

**A VM is not being updated:**

- Check that the QEMU guest agent is installed and running inside the VM, or configure SSH access (see [ssh.md](ssh.md)).
- Windows VMs are not supported.

**A container fails to snapshot:**

- Some storage types do not support snapshots. Enable `BACKUP_LXC_MP="true"` to fall back to a backup automatically, or set `SNAPSHOT="false"` and use `BACKUP="true"`.

---

## Contributing

Issues and pull requests are welcome at:
https://github.com/BassT23/Proxmox

Please check existing issues before opening a new one.

---

## License

[MIT](LICENSE)
