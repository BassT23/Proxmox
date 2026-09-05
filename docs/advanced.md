# Advanced operation

[← Back to README](../README.md)

This page collects settings that are useful for administrators who need more
control than the Quick Start provides.

## Filters

Check and Update filters are independent:

```text
CHECK ONLY:     ONLY_UPDATE_CHECK
CHECK EXCLUDE:  EXCLUDE_UPDATE_CHECK
UPDATE ONLY:    ONLY
UPDATE EXCLUDE: EXCLUDE
```

Values can contain VMIDs, inclusive ranges, and tags. `ONLY` takes precedence
over the matching `EXCLUDE`. A centrally skipped External target is not
contacted; target-local filters are applied afterwards.

## Job and status inspection

Use `ultimate-updater status --json` for the atomic status model and
`journalctl -u <unit>` for a server-side job's journal. Direct calls to
`check-updates.sh` and `update.sh` remain supported for local synchronous
operation, while the CLI update path starts the session-independent job
runner.

## User scripts

Place guest-specific scripts in
`/etc/ultimate-updater/scripts.d/<VMID>/`. Avoid spaces in filenames. An empty
`.script-only` marker runs those scripts instead of the built-in package
manager for that guest. Snapshot/backup and lifecycle safety still apply.

## Welcome screen and cached version information

The login welcome screen is optional. It reads locally cached version and
update information so a login is not dependent on a live network or remote
filesystem. The regular check refreshes that cache; it can also be refreshed
manually with `/etc/ultimate-updater/check-updates.sh`.

## Exit tracking

Commands placed in `/etc/ultimate-updater/exit` can be used for configured
success or failure follow-up actions. Keep these commands local, reviewed,
and free of credentials.

## Debugging

`DEBUG="true"` retains detailed transport, lifecycle, and job diagnostics.
Use it temporarily and return to `false` for normal user output. Do not put
credentials or private keys in configuration, scripts, or issue reports.

Related: [Configuration](configuration.md), [Troubleshooting](troubleshooting.md),
[Testing](../TESTING.md).
