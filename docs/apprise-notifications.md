# Generic notifications through Apprise

## Purpose and boundary

Ultimate Updater optionally uses the open-source Python `apprise` package
to deliver the existing status-model renderer output to supported providers.
This is **not** a second package checker, inventory, update engine or scheduler.
Native mail notifications remain available and preserve all existing policies.

## Optional configuration

Keep this feature disabled unless you explicitly configure a provider.
Install a reviewed, pinned `apprise` Python package into the Python interpreter
used by Ultimate Updater. Configuration is protected runtime state, not Git.

- `UU_APPRISE_URLS_FILE`: absolute path to a root-readable file, mode 0600,
  one Apprise provider URL per line; blank lines and `#` comments ignored.
  Supports any provider URL format supplied by installed Apprise.
- `UU_APPRISE_STATE_FILE`: optional absolute path to the dedupe state JSON;
  default `/var/lib/ultimate-updater/apprise-notification-state.json`.
- `UU_APPRISE_HELPER`: optional absolute helper path for custom installations.
- `UU_APPRISE_PYTHON`: optional absolute path to the executable inside a
  separately provisioned, pinned Apprise virtual environment. The default
  remains `python3`. Supply a path, never a shell command string. Using an
  isolated environment avoids changing host-managed Python dependencies.

The installer and upgrader install `notification-apprise.py` beside
`status-model.sh`. Configuration URLs are never passed via argv, printed to
terminal, copied to downstream source, or exposed through the Web UI.
Use a protected secret-delivery mechanism when deploying provider URLs.

For systemd jobs, `/etc/ultimate-updater/notification-integration.conf` is an
optional operator-provisioned EnvironmentFile containing paths and non-secret
integration settings. When present it must be a non-symlinked regular file
owned by the invoking service UID, with mode `0600`. Its parent must be owned
by that UID, not a symlink or group/other writable. Unsafe files prevent
job startup; a missing file preserves disabled-by-default behavior. Never
store provider URLs, tokens or other credentials in this EnvironmentFile.

## Semantics

Delivery is independently controlled from the existing email settings.
Check and update jobs reuse the native status model and human notification
renderer. Check notifications are deduplicated by stable target-state
fingerprints. An initial clean check does not produce a noisy alert;
changed updates/issues and recovery transitions are delivered once.
Manual update notifications track run start identity to permit distinct runs.

Each provider is delivered independently. Successful destinations are saved by
an irreversible provider-URL hash, so retrying one failed destination never
re-sends an already successful destination for the same event. A provider has a
15-second timeout and all destinations in one event share a 20-second delivery
budget. On timeout or failure, any remaining undelivered destinations are
retried on the next eligible event, while the successful check/update remains
successful. URLs and delivery exceptions are never logged or stored in state.

Corrupt delivery-state JSON resets deduplication so notifications resume. Unsafe
state file ownership, symlinks or permissions fail closed; protect the parent
directory and state file as root-only. State entries expire after 30 days and
the persisted map is capped at 1,024 identities.

Disabling is reversible by unsetting `UU_APPRISE_URLS_FILE`.

## Existing monitoring integration

This provider-neutral delivery feature does not replace external scheduling,
target-specific health checks or dead-man heartbeat services. If an existing
notification companion or monitoring integration provides those functions,
preserve it until check coverage, deduplication, manual-run semantics and
heartbeat parity pass live acceptance. Avoid overlapping alert destinations
during any eventual cutover.

## Test and maintenance

`bash tests/test-apprise-notifications.sh` uses a fake Apprise module and
an isolated interpreter wrapper. `bash tests/test-notification-unit-env.sh`
checks safe and unsafe EnvironmentFile ownership, mode and symlink cases.
These tests use synthetic providers and never send to external destinations. Existing
`bash tests/test-scheduled-check-notification.sh` and
`bash tests/test-mail-renderer.sh` verify email compatibility.
