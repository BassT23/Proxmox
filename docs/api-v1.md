# Ultimate Updater integration API v1

The integration API is a separate, read-only machine interface. It does not
replace the authenticated Web UI and it never starts a check, update, reboot,
cancel operation, QGA command, SSH check, or package manager.

## Enablement and tokens

API v1 is disabled unless `/etc/ultimate-updater/api-tokens.json` exists, is a
regular file owned by the Web UI service user, has mode `0600`, and contains
`"enabled": true`. The local administrator manages it with the installed
`ultimate-updater-api-token` command (or `api-token.sh` from the repository):

```text
sudo ultimate-updater-api-token enable
sudo ultimate-updater-api-token create homepage --permissions read
sudo ultimate-updater-api-token create hmc --permissions read,logs
sudo ultimate-updater-api-token list
sudo ultimate-updater-api-token revoke <token-id>
sudo ultimate-updater-api-token disable
```

Creation prints the secret exactly once. Store it in the integration's secret
store; it is never written to the configuration, returned by the API, or
written to logs. Tokens are 256-bit random values. The only supported v1
permissions are `read` and `logs`; `logs` also requires `read`.

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
* `GET /api/v1/jobs` — bounded cached job metadata.
* `GET /api/v1/jobs/{id}` — one validated Ultimate Updater job.
* `GET /api/v1/jobs/{id}/log` — bounded job output; requires `logs`.
* `GET /api/v1/updater-version` — local build metadata and an already cached
  public version result. It does not start a network version check.

Job IDs must match an Ultimate Updater job identifier. Arbitrary systemd unit
names, paths, commands, VMIDs, and query-token forms are rejected.

## Status contract

`/api/v1/status` exposes `id`, `name`, `type`, `node`, `transport`,
`reachable`, `os`, `updater`, `check_status`, `last_check`, update counts,
`reboot_required`, `last_update`, and bounded Windows Update metadata when it
is already present in the status model. Missing values remain `null`.

`/api/v1/status-summary` exposes counts for total, reachable, unreachable,
failed, unknown, available updates, and reboot requirements. Unknown values are
not converted to zero. `state` is `current`, `stale`, or `unknown`; the
timestamp and age are included where available. The default stale threshold is
86400 seconds and can be bounded by the existing `UU_STATUS_API_MAX_AGE_SECONDS`
setting (60–604800 seconds).

For example, a summary response has this shape (values are illustrative):

```json
{
  "api_version": 1,
  "schema_version": 1,
  "generated_at": "2026-10-17T10:00:00Z",
  "state": "current",
  "stale": false,
  "summary": {
    "targets": 3,
    "reachable": 2,
    "unreachable": 1,
    "failed": 0,
    "unknown_updates": 1,
    "unknown_reboot": 1
  },
  "updates_available": null,
  "reboot_required": null
}
```

The response is derived from the persisted status file. It does not imply
that any update was installed by Ultimate Updater; installation provenance is
available only from the corresponding persisted Ultimate Updater job metadata.

The API reads persisted status and cached job data. The API job list uses the
existing `job-runner list --cached` path without scheduling remote
reconciliation. It is therefore safe for regular polling and does not make a
fresh guest query.

## Errors and polling

`400` means invalid input, `401` missing/invalid authentication, `403` missing
permission, `404` missing data, `405` a non-GET API action, `503` disabled or
temporarily unavailable data. Error bodies have the form:

```json
{"error":{"code":"API_AUTH_REQUIRED","message":"A bearer token is required."}}
```

A status consumer should normally poll every 2–5 minutes. Poll jobs every
2–10 seconds only while a known job is active, and less often otherwise. The
API does not create a background polling task.

The older `/api/status-summary` endpoint remains available for compatibility
and uses the same hashed-token and HTTPS boundary; new integrations should use
`/api/v1/status-summary`.
