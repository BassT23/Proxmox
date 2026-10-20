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

## Optional pre-staged source input

An external release authority that has already approved and safely extracted a
release may opt in to the native `install` or `update` lifecycle without a new
GitHub download:

```bash
UU_STAGED_SOURCE_DIR=/root/accepted-source \
UU_STAGED_SOURCE_COMMIT=<accepted-40-character-Git-SHA> \
UU_STAGED_SOURCE_TAG=<accepted-release-tag> \
bash /root/accepted-source/install.sh update
```

This opt-in seam currently accepts the stable `master` branch only; beta and
development inputs continue to use their existing online branch paths.

All three values are required together. The source must be an absolute,
canonical, disposable directory owned by the invoking user, private to that
user (`0700` or equivalent setgid-private mode), outside
`/root/Ultimate-Updater-Temp`, without symlinks, and containing the complete
native installer payload. Invalid identity, partial input, unsafe ownership or
permissions, a wrong branch, an incomplete source, or a source in the native
temporary directory fails closed before installed files are changed. The
commit, tag, archive provenance and rollback decision remain the
responsibility of the external authority; this option is only a trusted local
source-directory seam and is not an archive verifier or deployment system.

With no `UU_STAGED_SOURCE_*` values, the existing online GitHub path is
unchanged. The accepted source is disposable because the native update
lifecycle may move files out of it. This interface was adapted for Ultimate
Updater from X1/X1pheR's proposal in Issue #373 and PR #374; Reach,
deployment, release and downstream workflow logic are intentionally excluded.

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
