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

The installer and upgrader install `notification-apprise.py` beside
`status-model.sh`. Configuration URLs are never passed via argv, printed to
terminal, copied to downstream source, or exposed through the Web UI.
Use a protected secret-delivery mechanism when deploying provider URLs.

## Semantics

Delivery is independently controlled from the existing email settings.
Check and update jobs reuse the native status model and human notification
renderer. Check notifications are deduplicated by stable target-state
fingerprints. An initial clean check does not produce a noisy alert;
changed updates/issues and recovery transitions are delivered once.
Manual update notifications track run start identity to permit distinct runs.

Provider delivery failure does not advance the delivered fingerprint and
does not change a successful check/update into an update failure. The
caller receives a generic error without echoing provider URL or credentials.
Failed notifications are retried on the next eligible event.

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
never sends to external destinations. Existing
`bash tests/test-scheduled-check-notification.sh` and
`bash tests/test-mail-renderer.sh` verify email compatibility.
