# Ultimate Updater 5.1.3 Beta 2

Status: Beta / release candidate for validation.

## Beta 2

- Interactive Live terminal support with persistent PTY sessions, reconnect and
  bounded replay for supported update jobs.
- Read-only Live output for checks and other non-interactive jobs.
- Improved mobile terminal usability, keybar support, and terminal font controls.
- Guarded `Reboot now` actions for supported nodes, LXC containers, and VMs.
- Clearer connectivity, APT/repository, disabled-check, and job-failure reporting.
- Scheduler month-day support and improved scheduled-check notification control.
- Job-scoped single-target notifications with explicit per-target summaries.
- Consistent English project-owned output, including explicit current/up-to-date
  targets instead of anonymous counts.
- Reliability fixes for terminal lifecycle, SSE/DOM handling, cleanup, and
  final job status propagation.

The Beta 2 contents are for validation and are not a stable 5.1.3 release.

## Fixed in 5.1.2

- Self-updates now handle release archives with a top-level directory and
  correctly locate the configuration migration helper.
- Archive validation no longer emits a misleading tar write error when
  checking for `update.sh`.
- Includes the previously approved guest overview column alignment polish.

The 5.1.1 fixes and compatibility notes remain documented below as the
baseline for this patch release.

## Fixed in 5.1.1

- QEMU Guest Agent updates now survive an agent restart during package
  upgrades (`264f85b6`, `566f8f68`).
- Remote cluster VMs receive the required QGA guest-exec helper (`173e15e9`).
- The post-update welcome/status check preserves the VM ID and rejects an
  empty one (`bbb3326`).
- The master installer now defaults to the stable `master` channel when no
  branch override is supplied (`152131d1`).
- Guest overview columns remain aligned across row types in the Web UI.

## Highlights

- Central Web UI for cluster status, checks, updates, jobs, logs, configuration, and External management.
- Session-independent systemd jobs that survive browser or SSH disconnects.
- Cluster-wide operation across Proxmox nodes with persistent status and locking.
- Separate CHECK and UPDATE filters with `ONLY` taking precedence over `EXCLUDE`.
- Read-only Check and Update previews using the corresponding runtime selection.
- A systemd-backed Scheduler for daily and selected-weekday Check/Update jobs,
  including selected target schedules.

## External systems

- External Linux support for APT and DNF over SSH.
- Dedicated SSH identity, non-root checks, and restricted root-owned helper/sudo access.
- Target-local `/etc/ultimate-updater/external.conf` settings with independent Check/Update filters.
- Global Update includes selected External targets while applying central filters before any remote contact.
- Recent manual backup verification or an explicit one-time owner override is required before External updates.

## Safety and reliability

- Snapshot/backup safety and lifecycle restoration for Proxmox guests.
- Bounded remote, QEMU Guest Agent, package-manager, and cluster execution paths.
- Continue-after-errors preserves the final non-zero run status.
- Safer configuration migration, self-update preservation, and notification behavior.
- Friendly job/status output, visible zero-update results, and deterministic golden-output regression tests.

## Web UI

- PAM-backed administrator login with session, CSRF, and same-origin protections.
- Default Web UI port `8765`, configurable locally with
  `ultimate-updater config set web-port PORT`.
- Port conflicts are reported without stopping or modifying the other process.
- Responsive desktop/mobile configuration, filter previews, External settings,
  job history, logs, and running-job visibility.

## Compatibility and fixes

- Existing VM SSH profiles under `/etc/ultimate-updater/VMs/<VMID>` remain
  supported for local and remote cluster paths. They do not need to be entered
  again in the Web UI. Internal SSH overrides are an additional, optional
  configuration path.
- QEMU Guest Agent detection accepts both legacy and current Proxmox agent
  property formats, including additional agent options.
- Guest lifecycle, QEMU guest-exec, remote-node refresh, target filtering,
  snapshot protection, and Community-Scripts execution paths received bounded
  failure handling and regression hardening.

## Upgrade notes

- Upgrade from 5.0 through the normal installer/self-update path.
- Existing installations can upgrade through the normal installer/self-update
  path using the stable `master` branch.
- Existing configuration, unknown keys, comments, External settings, and a
  custom Web UI port are preserved.
- Historical internal VM SSH profiles remain internal and are not exposed as
  External systems. Affected pre-release `[legacy-<VMID>]` artifacts are
  cleaned up safely during self-update without touching real External targets.
- Verify `ultimate-updater-web.service` is enabled and active after upgrade.
- Upgrading from version 5.0 or earlier to 5.1 requires a restart of the
  Proxmox host to fully complete the migration. The host remains usable before
  the restart, but some updater components may not work reliably until then;
  the updater does not reboot the host automatically.
- Upgrades within the 5.1 line do not require this migration restart; individual
  update results may still report `REBOOT REQUIRED`.

## Known limitations

- Windows support is prepared but remains experimental/deferred from the
  supported 5.1 baseline pending dedicated live validation.
- Automatic External backup integrations such as restic, borg, PBS workflows,
  or custom hooks are not implemented. Manual time-bound verification remains
  the current safety mechanism.

Stable software should still be used with current backups. Feedback and
reproducible test information are welcome.
