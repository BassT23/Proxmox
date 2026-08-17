# Upgrade notes: 5.0 → 5.1 Beta

Use the normal installer/self-update path on the existing central Proxmox
cluster installation. Ultimate Updater is installed once per cluster; do not
install a second administrative instance on every node.

To move an existing installation to the published 5.1 Beta, run:

```bash
update beta -up
```

The supported branch selectors are `master`, `beta`, and `develop`.

The migration preserves existing `update.conf` values, comments, unknown
settings, External target registrations, and any configured `WEB_UI_PORT`.
Missing supported defaults are added without overwriting user values. Legacy
compatible SSH target files are migrated safely and are not deleted.

After the upgrade:

1. Confirm `ultimate-updater-web.service` is enabled and active.
2. Open the configured Web UI port (default `8765`).
3. Confirm the existing Check/Update filters and External target settings.
4. If an External target has no helper yet, run its explicit External setup
   procedure before attempting an update.

The 5.1 Beta updater does not require a general Proxmox host reboot. A
particular update may still report that a reboot is required. External targets
are not rebooted automatically.

The current product filters remain:

```text
CHECK ONLY:     ONLY_UPDATE_CHECK
CHECK EXCLUDE:  EXCLUDE_UPDATE_CHECK
UPDATE ONLY:    ONLY
UPDATE EXCLUDE: EXCLUDE
```

`ONLY` takes precedence over the matching `EXCLUDE`, and Check and Update
filters remain independent.
