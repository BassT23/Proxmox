# Provider-neutral Apprise notifications

[← Back to Notifications](notifications.md)

## Scope

Issue #360 adds an optional transport for Apprise-compatible provider URLs.
The implementation follows the provider-neutral direction proposed in PR
[#364](https://github.com/BassT23/Proxmox/pull/364) by X1pheR, adapted to the
Ultimate Updater status model, scheduler, remote handoff, and safety boundary.
It does not add a second inventory, scheduler, database, update path, or
reboot action. Existing email notifications remain independent and unchanged.

The transport is disabled unless a protected provider file exists. It is not a
replacement for an external heartbeat or monitoring service; the later
success-heartbeat work from Issue #366 remains a separate concern.

## Protected configuration

Create `/etc/ultimate-updater/apprise-urls` as a regular, non-symlinked file
owned by the invoking service user (normally `root`) with mode `0600`. Put one
Apprise-compatible provider URL on each line. Empty lines and comments starting
with `#` are ignored. The helper accepts generic URL schemes and leaves
provider-specific validation to the installed Apprise package.

The file may be overridden for a controlled service/test environment with the
absolute `UU_APPRISE_URLS_FILE` environment variable. The path is still
validated for ownership, private permissions, regular-file type, non-symlink
status, bounded size, and a safe parent directory. Invalid or ambiguous
configuration fails closed and never falls back to an unsafe URL source.

Provider URLs, tokens, and credentials are never passed as command-line
arguments, written to `status.json`, included in API or WebUI output, or
printed in delivery errors. The optional helper path is
`UU_APPRISE_HELPER` (default: the installed `notification-apprise.py`), and the
optional state path is `UU_APPRISE_STATE_FILE` (default:
`/var/lib/ultimate-updater/apprise-notification-state.json`). These paths must
be absolute when overridden. `UU_APPRISE_PYTHON` may select an executable for
an isolated, pre-provisioned Python environment; it is a path, not a shell
command.

Remove the provider file or unset the override to disable the transport. No
update configuration migration is required, and no provider secret belongs in
`update.conf` or Git.

## Delivery semantics

The existing rendered check/update body is delivered without changing its
status meaning. Provider delivery is best-effort and never changes a check or
update exit code. Email and Apprise can therefore be enabled independently.

Each provider is attempted independently. A successful provider is recorded by
an irreversible SHA-256 identifier of its URL; the URL itself is not persisted.
If another provider fails, the next eligible delivery retries only the failed
provider. A provider attempt is limited to 15 seconds and one event has a
20-second total budget. Tests may only shorten these limits; they cannot extend
them.

Check notifications are deduplicated by the current target-state fingerprint.
The initial all-clear is suppressed, while changes and recovery transitions are
eligible for delivery. Update notifications include the existing run boundary,
so historical status records do not create a new event. A file lock and atomic
replacement protect concurrent writers. Malformed state resets deduplication so
notifications are not permanently suppressed; entries older than 30 days are
removed and at most 1,024 entries are retained.

Unsafe state files, state symlinks, invalid provider files, and a missing
Apprise dependency produce an observable generic notification error without
exposing provider data. The functional check/update result remains authoritative.

## Remote and external runs

Remote workers continue to use the existing status and update handoff. When a
worker is marked `UU_REMOTE_NODE_HANDOFF=true` or notification delivery is
deferred, it does not send an Apprise notification. The authoritative
controller sends the reconciled event once. External targets and manual runs
reuse the same status renderer and delivery policy; no target-specific provider
logic is introduced.

No Proxmox, guest, package-manager, snapshot, lifecycle, or reboot action is
performed by this transport.

## Safe local tests

`tests/test-apprise-notifications.sh` uses a fake local `apprise` module only.
It covers disabled operation, two-provider delivery, partial retry, bounded
timeouts, duplicate suppression, recovery, concurrent state protection,
corrupt-state recovery, retention, missing dependency, URL redaction, and
unsafe provider-file cases. It never contacts a provider or a Proxmox system.
