# Installation

## Install

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

The installer creates `/etc/ultimate-updater/` with the configuration file, libraries, plugins, and support files.

After installation, run the updater with:

```bash
update
```

---

## Update

Update to the latest stable release:

```bash
update master -up
```

Or run the installer directly:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
```

### Branches

| Command | Description |
|---|---|
| `update master -up` | Latest stable release |
| `update beta -up` | Beta branch |
| `update develop -up` | Development branch |

---

## Uninstall

```bash
update uninstall
```

Or:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) uninstall
```

---

## Installation status

Check whether The Ultimate Updater is installed:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) status
```

---

## Files installed

| Path | Description |
|---|---|
| `/etc/ultimate-updater/update.sh` | Main updater script |
| `/etc/ultimate-updater/update.conf` | Configuration file |
| `/etc/ultimate-updater/lib/` | Library files |
| `/etc/ultimate-updater/plugins/` | Plugin scripts |
| `/etc/ultimate-updater/run-plugins.sh` | Plugin runner |
| `/etc/ultimate-updater/check-updates.sh` | Update checker (welcome screen) |
| `/etc/ultimate-updater/VMs/` | Per-VM SSH configuration |
| `/etc/ultimate-updater/scripts.d/` | User scripts |
| `/usr/local/sbin/update` | Symlink — makes `update` available as a command |
