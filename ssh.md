# External systems over SSH

Ultimate Updater uses one central installation per Proxmox cluster. The
controller keeps the target inventory and notifications; remote execution is
performed over SSH.

## Recommended setup

Run the setup command on the controller for an already defined external
target:

```text
ultimate-updater external setup <target>
```

Setup creates the dedicated Ed25519 identity on demand if it does not exist.
It prints the public key and its fingerprint so an administrator can add the
key to the remote user's `~/.ssh/authorized_keys`. Passwords are never
requested, stored, or written to configuration. The private key remains on
the
controller and is never copied into the repository or sent by mail.

Host-key checking remains enabled. Confirm the remote host key before using a
target; do not disable `StrictHostKeyChecking` or use an empty
`known_hosts` file.

A normal remote user is recommended. Root SSH can work when it is already
provided by an administrator, but enabling `PermitRootLogin yes` is not part
of the setup.

## Target inventory

External targets are stored in `/etc/ultimate-updater/targets.conf`:

```ini
[external-linux]
host=192.0.2.50
transport=ssh
user=operator
port=22
identity_file=/root/.ssh/ultimate-updater-external
```

`identity_file` is optional. Its path is not a secret; the private-key
contents are. Existing SSH identities can continue to work for migrated
targets, so a legacy installation is not forced to replace a working key.

## Check and update privileges

An external check is read-only and does not require sudo. It reads the
remote OS information, uses the existing local package metadata for a
simulation, and checks the reboot marker. For APT systems it does not run
`apt-get update`, so the reported count may reflect cached metadata.

An update uses the root-owned remote helper:

```text
/usr/local/sbin/ultimate-updater-external
```

The administrator installs that helper and its restricted sudoers entry with
the bootstrap output from `external setup` (or by an explicit local admin
procedure). The helper detects the operating system itself and accepts only
the fixed `update` action. The sudoers rule allows that helper action only;
it is not `NOPASSWD: ALL`. The helper is root-owned and is not installed
from a user-writable directory.

For APT systems the helper runs the unattended update sequence with
`DEBIAN_FRONTEND=noninteractive`, `--force-confdef`, and
`--force-confold`, followed by autoremove and autoclean. No automatic reboot
is performed; a required reboot is reported. DNF support is available in the
helper, but should be treated as a separately validated platform path.

External systems do not receive Proxmox snapshots or vzdump backups. Before
an external update, an administrator must have a current verified backup or
explicitly accept the risk of proceeding.

## Historical internal VM SSH profiles

Older installations may contain one SSH profile per internal Proxmox VM under:

```text
/etc/ultimate-updater/VMs/<ID>
```

These files are not External targets and are never added to `targets.conf`.
The internal VM check/update path reads `IP`, `USER`, and `SSH_VM_PORT` from
the matching file for SSH fallback; `SSH_START_DELAY_TIME` remains an internal
retry delay. The files and working SSH identities are preserved.

Early 5.1 Beta builds could incorrectly create `[legacy-<VMID>]` External
sections. A later self-update removes only sections with migration evidence
whose host/user/port exactly match the corresponding VM profile. The cleanup
backs up and atomically validates `targets.conf`; real External targets are
preserved. No legacy file is sourced or evaluated.

Internal VM SSH fallback remains usable through the existing VM path; External
helper setup is unrelated and applies only to actual External systems.
