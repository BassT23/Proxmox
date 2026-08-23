# Backup and snapshots

[← Back to README](../README.md)

Snapshots and backups are independent safety mechanisms. A snapshot can be
requested without enabling a backup, and an unsupported snapshot does not
silently turn into a backup. Backup behavior is selected explicitly through
the configured backup mode.

Relevant settings include:

- `SNAPSHOT` and `KEEP_SNAPSHOTS`
- `BACKUP` and `BACKUP_MODE`
- `BACKUP_LXC_MP`
- `BACKUP_STORAGE`

`BACKUP_STORAGE` is a Proxmox Storage ID, not a filesystem path, PBS
datastore name, or mount point. Discover active backup-capable IDs with:

```bash
pvesm status -content backup
```

For example, use `BACKUP_STORAGE="pbs"` when `pbs` is the Proxmox storage ID.
Leave it empty to keep automatic selection. An unknown or inactive ID is
rejected rather than silently falling back.

Review storage capacity and restore procedures before enabling updates. The
updater reports backup/snapshot failures and does not claim that protection
was created when it was not.

External systems are not given Proxmox snapshots or vzdump backups; their
separate backup-verification gate is described in [External systems](external-systems.md).

Related: [Configuration](configuration.md), [Checks and updates](checks-and-updates.md).
