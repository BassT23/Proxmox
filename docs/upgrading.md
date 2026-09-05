# Upgrading

[← Back to README](../README.md)

Use the normal installer/self-update path on the existing central Proxmox
installation. For a stable installation, use the master branch:

```bash
update master -up
```

The bare `update -up` targets stable `master`. The selected branch is kept as
installed metadata but does not change the target of a bare update.

Upgrades preserve existing `update.conf` values, comments, unknown settings,
External target registrations, and a configured Web UI port. Missing
supported defaults are added without replacing user values. Historical
`VMs/<VMID>` files remain internal VM SSH profiles and are not converted into
External inventory.

After upgrading, confirm that `ultimate-updater-web.service` is enabled and
active, open the configured Web UI, and review Check/Update filters and
External settings. A 5.0-to-5.1 migration can require a Proxmox host restart
to complete the service/job infrastructure migration; the updater does not
reboot the host automatically. Updates within the 5.1 line do not require
that migration restart, though individual package/kernel updates may report
their own reboot requirement.

For the detailed release-specific notes, see
[`UPGRADE_NOTES_5.1.md`](../UPGRADE_NOTES_5.1.md) and
[`RELEASE_NOTES_5.1.md`](../RELEASE_NOTES_5.1.md).

Related: [Installation](installation.md), [Troubleshooting](troubleshooting.md).
