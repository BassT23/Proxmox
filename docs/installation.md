# Installation

[← Back to README](../README.md)

## Requirements

Install Ultimate Updater as root on one supported Proxmox VE host. A cluster
uses one central installation; a standalone node can run it by itself. Do not
install a separate administrative instance on every cluster node.

For cluster operation, nodes must resolve each other by the names and
addresses used by Proxmox and have working SSH fingerprints. VMs included in
checks or updates need either a working QEMU Guest Agent with `guest-exec` or
configured key-based SSH; see [SSH and VM access](ssh.md) for the detailed
guest requirements. Keep current backups before enabling mutating updates.

## Install

Stable `master`:

```bash
installer=$(mktemp)
curl -4 -fSL --retry 0 https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh -o "$installer" && \
  bash -n "$installer" && bash "$installer"
rm -f "$installer"
```

The installer validates its inputs and keeps the existing configuration.

## Operator-provided staged source (native install input)

When an external release/deployment authority has **already** independently
verified a source artifact and extracted it into a protected local directory,
the existing native `install` and `update` actions can consume that source
without fetching a new archive:

```bash
UU_STAGED_SOURCE_DIR=/root/accepted-source \
UU_STAGED_SOURCE_COMMIT=<accepted-40-character-Git-SHA> \
UU_STAGED_SOURCE_TAG=<accepted-release-tag> \
  bash /root/accepted-source/install.sh update
```

**This is a native source-directory input, not an offline artifact verifier or
a second deployment system.** The external authority owns the archive
checksum, immutable release/tag and provenance checks, safe TAR extraction,
root-private staged source, exact preimage/rollback and live runtime parity.
The source directory must be a non-symlinked absolute canonical directory
owned by the installer's execution identity, with no group/other access
(e.g. mode `0700` or setgid-inherited `2700`), outside the installer's own
temporary directory, and include regular non-symlinked
`update.sh` and `product-metadata.sh`. All three environment values are
required together; a missing or invalid value fails closed. An accepted
staging directory must be **disposable**: the native update lifecycle moves
source files as part of installation and may consume its contents.

The default online installer path remains unchanged when no staged-source
values are supplied. This interface does not independently prove the Git
source commit generated the staged files and does not grant permission for a
privileged installation. The external operator must independently approve
and test an exact rollback before running `install` or `update` on a real
Proxmox host.

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
