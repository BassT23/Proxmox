# Installation

[← Back to README](../README.md)

## Requirements

Install Ultimate Updater as root on one Proxmox host. A cluster uses one
central installation; a standalone node can run it by itself. Cluster nodes
must resolve each other by the names and addresses used by Proxmox and have
working SSH fingerprints.

## Install

Stable `master`:

```bash
installer=$(mktemp)
curl -4 -fSL --retry 0 https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh -o "$installer" && \
  bash -n "$installer" && bash "$installer"
rm -f "$installer"
```

Published Beta:

```bash
installer=$(mktemp)
curl -4 -fSL --retry 0 https://raw.githubusercontent.com/BassT23/Proxmox/beta/install.sh -o "$installer" && \
  bash -n "$installer" && UU_TARGET_BRANCH=beta bash "$installer"
rm -f "$installer"
```

The installer validates its inputs and keeps the existing configuration. Do
not install a second administrative instance on every cluster node.

## First steps

1. Review `/etc/ultimate-updater/update.conf`.
2. Prepare VM access if VMs are included; see [SSH and VM access](ssh.md).
3. Add external systems only when needed; see [External systems](external-systems.md).
4. Confirm `ultimate-updater-web.service` is active.
5. Open `https://<proxmox-node>:8765/` and run a check before an update.

To inspect help from the host, run `update -h` or `ultimate-updater --help`.

## Removing or repairing an installation

Use the installer from the same branch with the `uninstall` action only after
reviewing what is installed. Keep `/etc/ultimate-updater/update.conf` and
backups if you plan to reinstall.

Related: [Upgrading](upgrading.md), [Configuration](configuration.md).
