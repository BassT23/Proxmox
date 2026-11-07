# Upgrade notes: 5.1.3 to 5.2

Status: 5.2 development and Beta candidate. These notes describe the current
develop/beta upgrade paths; they do not announce a stable release.

## Choose the channel explicitly

Ultimate Updater is installed once on the central Proxmox installation. Use
the existing self-update path and select the channel deliberately:

```bash
# Stable master remains the default target for a bare update.
update master -up

# Use one of these only when the corresponding pre-release channel is intended.
update beta -up
update develop -up
```

The bare `update -up` continues to target `master`. The installed branch is
recorded in build metadata, while the explicit `beta` or `develop` selector
chooses the source to install. Do not infer a release or Beta number from the
branch name; verify the installed build identity with the normal status or
version view.

## What the upgrade preserves

The existing installer/self-update path merges the target defaults into the
current configuration without executing the configuration file. Existing
values, comments, unknown settings, External registrations, and the configured
Web UI port are preserved. Missing supported defaults are added safely.

The following state remains user-owned and is not replaced by the repository
payload:

- `update.conf` and its migrated defaults;
- `target-selection.json` and its Check/Update selection rules;
- `status.json`, job state, and runtime workspaces;
- internal `VMs/<VMID>` SSH profiles;
- External target configuration and helper state.

The installer also validates the target configuration migration helper before
replacing installed files. A source-release pin or an invalid staged source
blocks source replacement before mutation.

## Restart and reboot behavior

An upgrade from the 5.1.3 line to 5.2 does not require a general Proxmox host
restart in the existing migration logic. The Web UI service is restarted by
the installer as part of the normal installation/update path.

Individual package or kernel updates may still report `REBOOT REQUIRED`; that
status belongs to the updated system and is not an automatic host reboot by
the updater. The older 5.0-to-5.1 migration restart requirement remains a
historical compatibility case and is not a 5.1.3-to-5.2 prerequisite.

## Before and after the upgrade

Before changing channels:

1. Keep a current, restorable backup of the Proxmox installation and relevant
   updater configuration.
2. Confirm that the intended branch is `master`, `beta`, or `develop` and that
   the source-release pin policy permits the requested source replacement.
3. For a pre-release channel, review the corresponding release notes and use
   a maintenance window appropriate for the installation.

After the command completes:

1. Confirm that `ultimate-updater-web.service` is enabled and active.
2. Open the configured Web UI port, which defaults to `8765`.
3. Confirm the displayed product version, branch, and build identity.
4. Confirm that `update.conf`, External settings, VM SSH profiles, and the
   existing Check/Update target-selection rules are present.
5. Review the status page and run a read-only check before scheduling updates.
6. Complete any required External helper or verified-backup setup before an
   External update.

If an upgrade is interrupted, use the previously verified release and normal
configuration backup/rollback procedure. Do not replace user-owned runtime
state with a repository fixture or manually bypass the updater's safety gates.

## Known limitations

- 5.2 remains a development/Beta candidate rather than a stable release.
- Windows checks and opt-in updates remain bounded by the documented QGA/SSH,
  servicing, and validation requirements.
- External updates remain blocked when the required recent verified backup is
  unavailable.
- The integration API is under development and may change before stable
  release.
