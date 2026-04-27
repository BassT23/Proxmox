# The Ultimate Updater for Proxmox VE — Wiki

A single command to update your entire Proxmox environment: the host, all LXC containers, and all VMs.

---

## Pages

- [Installation](Installation)
- [Configuration](Configuration)
- [VM Updates via SSH](VM-Updates-via-SSH)
- [Cluster Mode](Cluster-Mode)
- [Plugins](Plugins)
- [Welcome Screen](Welcome-Screen)
- [User Scripts](User-Scripts)
- [Troubleshooting](Troubleshooting)

---

## Quick start

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

Then run:

```bash
update
```

---

## Requirements

- Proxmox VE 7 or later
- Root access on the Proxmox host
