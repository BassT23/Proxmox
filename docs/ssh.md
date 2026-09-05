# SSH and VM access

[← Back to README](../README.md)

## VM transport

VMs can use a QEMU Guest Agent or SSH. QGA is convenient when both agent
readiness and guest execution are available:

```bash
qm agent <VMID> ping
qm guest exec <VMID> -- true
```

If an active Internal SSH override exists, SSH is preferred. Disabling that
override leaves its saved values in place but removes it from runtime
resolution, allowing the default/QGA path to take over. Removing the
override deletes the saved override. These are different operations.

The SSH path uses key-based authentication. The Web UI displays a path/source
and connection metadata, never private-key contents or passwords.

## Internal SSH overrides

Validated overrides for Proxmox nodes and internal VMs are stored in
`/etc/ultimate-updater/internal-ssh.conf`. The Web UI can show, test, edit,
disable, and remove them. An enabled override is labeled as an Internal SSH
override; a saved but disabled one is shown as disabled and is not used.

Without an override, nodes use their cluster address and global SSH defaults.
VMs use a matching legacy profile when present or fall back to QGA/default
resolution.

Older installations may have `/etc/ultimate-updater/VMs/<VMID>` files with
`IP`, `USER`, `SSH_VM_PORT`, and `SSH_START_DELAY_TIME`. These are internal VM
profiles, not External targets, and are not copied into `targets.conf`.
They remain supported for local and remote VM paths in a Proxmox cluster, so an
existing working SSH profile does not need to be entered again in the Web UI.

## External systems

External SSH systems use `/etc/ultimate-updater/targets.conf` and a dedicated
identity where configured. See [External systems](external-systems.md) for
setup and privilege boundaries.

Related: [Cluster operation](cluster.md), [Supported systems](supported-systems.md),
[Troubleshooting](troubleshooting.md).
