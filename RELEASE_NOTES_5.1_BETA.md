# Ultimate Updater 5.1 Beta

Status: Published 5.1 Beta release.

## Highlights

- Central Web UI for cluster status, checks, updates, jobs, logs, configuration, and External management.
- Session-independent systemd jobs that survive browser or SSH disconnects.
- Cluster-wide operation across Proxmox nodes with persistent status and locking.
- Separate CHECK and UPDATE filters with `ONLY` taking precedence over `EXCLUDE`.
- Read-only Check and Update previews using the corresponding runtime selection.

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

## Upgrade notes

- Upgrade from 5.0 through the normal installer/self-update path.
- Existing installations can select the published Beta with `update beta -up`.
- Existing configuration, unknown keys, comments, External settings, and a
  custom Web UI port are preserved.
- Legacy compatible External SSH entries are migrated without deleting the
  original configuration.
- Verify `ultimate-updater-web.service` is enabled and active after upgrade.
- Upgrading from 5.0 to 5.1 requires a restart of the Proxmox host after the
  upgrade; the updater does not reboot automatically.
- Upgrades within the 5.1 line do not require this migration restart; individual
  update results may still report `REBOOT REQUIRED`.

## Known limitations

- Windows support is prepared but remains experimental/deferred from the
  supported Beta baseline pending dedicated live validation.
- Automatic External backup integrations such as restic, borg, PBS workflows,
  or custom hooks are not implemented. Manual time-bound verification remains
  the current safety mechanism.

Beta software should be used with current backups. Feedback and reproducible
test information are welcome.
