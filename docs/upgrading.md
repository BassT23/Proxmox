# Upgrading

[← Back to README](../README.md)

Use the normal installer/self-update path on the existing central Proxmox
installation. For a stable installation, use the master branch:

```bash
update master -up
```

The bare `update -up` targets stable `master`. The selected branch is kept as
installed metadata but does not change the target of a bare update.

## Externally managed source releases

Operators distributing their own reviewed Ultimate Updater source can opt out
of the built-in **Updater source replacement** without disabling normal package,
host or guest updates. Create the generic local marker
`/etc/ultimate-updater/.source-release-pin` using the external release owner's
procedure. When present, including as a dangling symlink, `update -up`,
explicit branch replacement, and downloaded installer replacement refuse to run
before any source-replacement download. Uninstall remains available. With no
marker, the normal upstream behavior is unchanged.

Only remove the marker as part of a deliberate, externally verified release or
rollback procedure. The marker is an opt-in local guard; it does not provide
signature, checksum, provenance, or release verification. The external release
authority remains responsible for reviewing, verifying, installing, and
rolling back the source. The marker also does not replace the separate trusted
staged-source checks documented in [Installation](installation.md): a staged
source must still satisfy that interface's identity, ownership, permissions,
canonical-path, and complete-payload requirements.

This upstream adaptation follows the implementation direction from X1/X1pheR's
Issue #370 and PR #371; downstream-specific names and release/deployment
workflow logic are intentionally not included.

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
