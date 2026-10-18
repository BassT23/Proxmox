# Ultimate Updater integration API v1

The integration API is a separate machine interface. Its API-1 read endpoints
are read-only; API-2 adds explicitly permissioned action endpoints below. It
does not replace the authenticated Web UI or create a second update engine.

## Enablement and tokens

API v1 is disabled unless `/etc/ultimate-updater/api-tokens.json` exists, is a
regular file owned by the Web UI service user, has mode `0600`, and contains
`"enabled": true`. The local administrator manages it with the installed
`ultimate-updater-api-token` command (or `api-token.sh` from the repository):

```text
sudo ultimate-updater-api-token enable
sudo ultimate-updater-api-token create homepage --permissions read
sudo ultimate-updater-api-token create hmc --permissions read,logs
sudo ultimate-updater-api-token create monitor-checker --permissions check
sudo ultimate-updater-api-token create maintainer --permissions read,check,update
sudo ultimate-updater-api-token list
sudo ultimate-updater-api-token revoke <token-id>
sudo ultimate-updater-api-token disable
```

Creation prints the secret exactly once. Store it in the integration's secret
store; it is never written to the configuration, returned by the API, or
written to logs. Tokens are 256-bit random values. The supported permissions
are `read`, `logs`, `check`, `update`, `reboot`, and `cancel`. `logs` also
requires `read`; action permissions are independent and do not imply `read`.

Use exactly one header:

```text
Authorization: Bearer <token>
```

API tokens do not authorize Web UI session endpoints or Web UI write actions.
HTTPS is required; proxy headers do not enable an HTTP fallback. Responses use
`Cache-Control: no-store`.

## Endpoints

All responses are JSON and contain `api_version: 1` and `schema_version: 1`
where a response object is returned.

* `GET /api/v1/status-summary` — bounded aggregate status.
* `GET /api/v1/status` — public target status records.
* `GET /api/v1/jobs` — bounded cached job metadata. An optional
  `?target=<managed-target>` filter is applied before the visible job limit.
* `GET /api/v1/jobs/{id}` — one validated Ultimate Updater job.
* `GET /api/v1/jobs/{id}/log` — bounded job output; requires `logs`.
* `GET /api/v1/updater-version` — local build metadata and an already cached
  public version result. It does not start a network version check.
* `GET /api/v1/capabilities` — read-only configured lifecycle and API
  capability metadata.

Job IDs must match an Ultimate Updater job identifier. Arbitrary systemd unit
names, paths, commands, VMIDs, and query-token forms are rejected. The job
filter accepts a managed target reference such as `118`, `guest:118`, or
`host:node1`; it returns `404` for a valid but unmanaged or ambiguous target
and `400` for invalid or repeated `target` parameters. Filtering happens
before the bounded visible-job limit. No target filter leaves the existing job
list behavior unchanged.

## Status contract

`/api/v1/status` exposes `id`, `name`, `type`, `node`, `transport`,
`reachable`, `os`, additive `os_display`, `updater`, `check_status`, `last_check`, update counts,
`reboot_required`, `last_update`, `error`, optional `skip_reason`, and bounded
Windows Update metadata when it is already present in the status model. Missing
values remain `null`; `os_display` is the normalized human-readable label
(`Debian 13`, for example) and is `Unknown` when the existing OS metadata is
missing or insufficient. It never performs a guest query or invents a version.
For example, a target may contain both the unchanged raw value and the
additive display value:

```json
{"os": "Debian GNU/Linux 13 (trixie)", "os_display": "Debian 13"}
```

`error` is either `null` or a bounded object containing a validated error code
and a generic public message. The API never exposes raw command output, stack
traces, credentials, tokens, or other diagnostic text from the status model.
A real check failure has an `error` object and `skip_reason: null`.

`skip_reason` is neutral metadata for a check that was intentionally not
performed; it is not a check failure. A target with a skip has
`check_status: "not_checked"` (or another legacy neutral status),
`error: null`, and a bounded object such as:

```json
"skip_reason": {
  "code": "STOPPED_READ_ONLY",
  "message": "LXC 910 is stopped; the check did not start it"
}
```

Known neutral codes include `STOPPED_READ_ONLY`, `PAUSED_READ_ONLY`,
`RUNNING_DISABLED`, `CHECK_DISABLED`, `CHECK_WITH_HOST_DISABLED`,
`NETWORK_UNAVAILABLE`, `UNSUPPORTED_GUEST_OS`, and `NO_SUPPORTED_TRANSPORT`.
Operational failures such
as `CHECK_COMMAND_FAILED`, `LIFECYCLE_RESTORE_FAILED`, and
`API_TARGET_IDENTITY_MISMATCH` remain errors and are never converted to a
skip. A neutral skip has `error: null`; a successful check has both
`error: null` and `skip_reason: null`. Older status files without either
optional field remain valid and expose the missing values as `null`.

`last_check` records when the target's check observation was written. It can
change for an intentional skip, so `check_status: "not_checked"` means that
package data was not queried and must not be interpreted as fresh package
information. Consumers should use the per-target `last_check` together with
`check_status` and `skip_reason`; the document-level freshness state describes
the status document, not proof that every target was checked.

`package_checked_at` is an internal status-model provenance field. It is set
only after a supported package backend returned a valid update count for the
correct target. Skips, failed checks, operating-system discovery, Windows
Update History-only queries, and update jobs without a successful post-check do
not refresh it. A successful post-update check may refresh it. Older status
files may not contain the field; the API does not invent a timestamp from
`last_check`, `generated_at`, `last_update.timestamp`, or Windows history.
Legacy records without explicit package-check provenance are therefore
`unknown`, except for an explicit neutral never-checked state, which is
`not_checked`.

The internal `package_data_invalidated` marker is set before a potentially
package-changing update path begins and remains set after failed, interrupted,
or incomplete updates. It is cleared only by a later validated package check.
It is not exposed as an API control field. This also makes an update and a
post-update check in the same second unambiguous: the valid post-check clears
the marker rather than relying on timestamp ordering alone.

Each target in `/api/v1/status` additionally contains:

```json
"package_freshness": {
  "state": "current",
  "checked_at": "2026-10-17T10:00:00Z",
  "age_seconds": 3600
}
```

`package_freshness.state` is independent of the document-level `state`:

* `current` — valid package data exists and its proven check is within the
  package freshness TTL.
* `stale` — a proven package check exists, but it is older than the TTL or a
  later update event invalidated its confirmation.
* `not_checked` — no successful package check is known, and the latest state
  is neutral or has never been checked.
* `unknown` — timestamps, package data, or provenance are missing, invalid, or
  contradictory.

For document-level freshness, `stale` is `false` when `state` is `current`,
`true` when `state` is `stale`, and explicitly `null` when `state` is
`unknown`; `null` means that the document age could not be classified and is
not equivalent to either fresh or stale.

`checked_at` is the proven package-check time, not the status-file write time,
the observation time, `last_update.timestamp`, or the Windows History query
time. `age_seconds` is non-negative and is `null` when the timestamp is
missing, invalid, naive, or outside the accepted future clock-skew tolerance.
Missing package counts make the state `unknown` even when an old
`checked_at` is retained. A neutral skip may leave an earlier valid package
freshness state in place, but it never renews `checked_at`.

The package freshness TTL defaults to 86400 seconds and is evaluated on every
API request. It can be configured with
`UU_API_PACKAGE_FRESHNESS_MAX_AGE_SECONDS`, bounded to 60–604800 seconds. The
invalid, empty, non-numeric, or out-of-range values use the bounded default;
they never create an unlimited TTL or stop the WebUI. The document freshness
threshold remains independently controlled by
`UU_STATUS_API_MAX_AGE_SECONDS`. Both `/api/v1/status` and
`/api/v1/status-summary` use the same timezone-aware timestamp rules: missing,
naive, invalid, and far-future values are `unknown`, and negative ages are
never returned.

`/api/v1/status-summary` exposes counts for total, reachable, unreachable,
failed, unknown, available updates, and reboot requirements. Unknown values are
not converted to zero. `state` is `current`, `stale`, or `unknown`; the
timestamp and age are included where available. The additive
`package_freshness` object contains `current`, `stale`, `not_checked`, and
`unknown` counts, whose sum equals the number of targets. Its classification is
the same one used for individual `/api/v1/status` targets. The summary's
`age_seconds` describes only `generated_at`; document-level `state: "current"`
does not mean that every target's package data is current.

For example, a summary response has this shape (values are illustrative):

```json
{
  "api_version": 1,
  "schema_version": 1,
  "generated_at": "2026-10-17T10:00:00Z",
  "state": "current",
  "stale": false,
  "age_seconds": 0,
  "summary": {
    "targets": 3,
    "reachable": 2,
    "unreachable": 1,
    "failed": 0,
    "unknown_updates": 1,
    "unknown_reboot": 1
  },
  "package_freshness": {
    "current": 2,
    "stale": 0,
    "not_checked": 1,
    "unknown": 0
  },
  "updates_available": null,
  "reboot_required": null
}
```

The response is derived from the persisted status file. It does not imply
that any update was installed by Ultimate Updater; installation provenance is
available only from the corresponding persisted Ultimate Updater job metadata.

An update result with `last_update.status: "skipped"` or `"unsupported"` is a
neutral no-op/capability result, not a successful package mutation. An update
job with no confirmed package mutation is exposed as terminal state `skipped`;
it is not `completed` or `completed_with_warnings`. For update jobs, the
`completed_with_warnings` state is reserved for an update that actually ran
and completed, but whose required post-update status capture or result
preservation could not be confirmed. Clients must therefore distinguish the
terminal job state from a target's persisted `last_update` result.

The API reads persisted status and cached job data. The API job list uses the
existing `job-runner list --cached` path without scheduling remote
reconciliation. It is therefore safe for regular polling and does not make a
fresh guest query.

## Capabilities

`GET /api/v1/capabilities` is read-only and requires the existing `read`
permission. It reads only the configured `CHECK_*` and update-selection values
from `update.conf`; it does not contact Proxmox, guests, SSH, QGA, a package
manager, or the job runner. The response contains `api_version: 1` and
`schema_version: 1` and does not expose configuration text, credentials, or
tokens. Missing or invalid boolean settings are represented as
`configured: null` and `behavior: "unknown"`.

The lifecycle section distinguishes normal checks from initial inventory and
updates. For example:

```json
{
  "api_version": 1,
  "schema_version": 1,
  "capabilities": {
    "stopped_container": {
      "check": {
        "configured": true,
        "normal_behavior": "lifecycle_check",
        "initial_inventory_behavior": "read_only_skip"
      },
      "update": {
        "configured": false,
        "behavior": "skipped"
      }
    }
  }
}
```

`lifecycle_check` means the configured normal check path may apply its
existing lifecycle policy; `lifecycle_update` means the configured update path
may apply its existing lifecycle policy. A `skipped` value means that mode is
disabled by configuration. These values describe configuration and existing
semantics, not a claim that a particular target is reachable or updateable.
Initial inventory is always reported as `read_only_skip` for stopped and
paused guests. The endpoint does not change those lifecycle rules.

## Errors and polling

`400` means invalid input, `401` missing/invalid authentication, `403` missing
permission, `404` missing data, `405` a non-GET API action, `503` disabled or
temporarily unavailable data. Error bodies have the form:

```json
{"error":{"code":"AUTH_REQUIRED","message":"A bearer token is required."}}
```

A status consumer should normally poll every 2–5 minutes. Poll jobs every
2–10 seconds only while a known job is active, and less often otherwise. The
API does not create a background polling task.

The older `/api/status-summary` endpoint remains available for compatibility
and uses the same hashed-token and HTTPS boundary; new integrations should use
`/api/v1/status-summary`.

## API-2 scoped actions

API-2 extends the versioned API with explicitly authorized actions. It does
not replace the Web UI action handlers or create a second job engine. Every
action is validated against the persisted managed inventory and is submitted
to the existing job runner. A successful response means only that the job was
accepted; follow its `job` identifier through the API-1 job endpoints.

Checks do not require a confirmation body and run with the existing
`UU_JOB_SOURCE=initial-inventory` and `UU_NONINTERACTIVE=true` context. This
reuses the lifecycle-safe check path: stopped guests are not started and
paused VMs are not resumed.

Updates and reboots require exactly this JSON body:

```json
{"confirm": true}
```

The API update paths use the normal update safety checks and never add the
`--without-verified-backup` override. They run with the explicit context
`UU_API_ACTION=update`, `UU_NONINTERACTIVE=true`, and
`UU_API_REBOOT_ALLOWED=false` across local, remote, and external dispatch
boundaries. This context is not an authorization mechanism; the `update`
permission is checked at the HTTP boundary first.

API updates fail closed before the first backup, snapshot, guest start, or
package-manager mutation when the selected target would execute a script-only,
custom, community, helper, or other optional script path. The response uses
`409` with error code `API_UNSAFE_SCRIPT_PATH`. Optional paths that are
provably absent are skipped rather than being reported as successful script
execution. For an originally stopped Linux guest, an optional path that cannot
be inspected without starting the guest is rejected with
`API_PREFLIGHT_UNAVAILABLE`; the guest is not started to perform the check.
When that condition can only be established by the executing update worker,
the action may already have returned `202 Accepted`; in that case the job
terminates with the same error and no guest lifecycle action is performed.
The same guard is retained in the runtime for older or indirect callers. This
restriction applies only to API updates; Web UI, CLI, and scheduler behavior
is unchanged.

The current update engine reports reboot requirements separately; reboot is an
explicit action with its own `reboot` permission. API updates never trigger an
automatic Ultimate Updater reboot, even when `REBOOT_IF_NEEDED=true`. The
separate reboot endpoint remains protected by its existing target, reachability,
reboot-required, and permission checks. Root-owned package maintainer scripts
may still request or perform behavior outside Ultimate Updater's control; the
API guarantee is limited to reboots initiated by the updater's controlled
paths. API-2 does not expose global update-all or self-update.

| Endpoint | Permission | Purpose |
| --- | --- | --- |
| `POST /api/v1/check/{id}` | `check` | Check one known managed guest target |
| `POST /api/v1/check-node/{node}` | `check` | Check one known Proxmox node |
| `POST /api/v1/check-all` | `check` | Start the existing global check |
| `POST /api/v1/update/{id}` | `update` | Start one normal, safety-gated update |
| `POST /api/v1/update-node/{node}` | `update` | Update the node host only |
| `POST /api/v1/reboot/{id}` | `reboot` | Use the existing reboot safety path |
| `POST /api/v1/jobs/{id}/cancel` | `cancel` | Request cancellation of one running UU job |

Action responses use `202 Accepted` and have the following shape:

```json
{
  "api_version": 1,
  "schema_version": 1,
  "job": "ultimate-updater-check-986-20261017-120000-1234",
  "target": "986",
  "type": "check",
  "state": "running"
}
```

`409 Conflict` is returned for an existing job conflict, unmet backup safety
requirements, an unsafe API script path, or a reboot that is not currently
required. `422` is used for
missing confirmation or rejected action parameters, `404` for unknown targets
or jobs, and `503` when the local API data or action infrastructure is
temporarily unavailable. HTTPS is required before authentication or any
action side effect; bearer tokens never authorize Web UI or CSRF-protected
administrative endpoints.

Recommended polling remains 2–5 minutes for status and 2–10 seconds only
while an explicitly started job is active. API-2 adds no background polling.
