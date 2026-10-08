# Read-only status summary API

## Contract

`GET /api/status-summary` is an optional machine-to-machine endpoint for dashboards.
It reads the existing Ultimate Updater status file only, without running checks,
jobs, inventory discovery, system updates or Proxmox commands.
It never returns target IDs, hostnames or error details.

The endpoint is disabled by default. Configure `UU_STATUS_API_TOKEN_FILE` as
the absolute path to an operator-provisioned token file with mode `0600` and
a random ASCII token at least 24 characters long. Keep it outside Git.
Use TLS and restrict direct backend network access.
Web UI session cookies do not authorize machine access.
Provide exactly one `Authorization: Bearer <token>` header.

Unconfigured/invalid credentials return 503, unauthorized requests 401,
missing status 404 and invalid or oversized status 422.
Responses use `Cache-Control: no-store`.

## Response schema v1

```json
{
  "schema_version": 1,
  "state": "current",
  "generated_at": "2026-10-08T10:00:00Z",
  "targets": {
    "total": 3, "reachable": 2, "unreachable": 1,
    "failed": 1, "unknown_updates": 1, "unknown_reboot": 1
  },
  "updates_available": null,
  "reboot_required": null
}
```

Aggregate updates/reboot counts are null whenever at least one target lacks
a known value; unknown must not be converted to zero. State is `stale` when
`generated_at` is missing, invalid, future-dated, or older than the threshold.
Default `UU_STATUS_API_MAX_AGE_SECONDS` is 86400 (allowed 60 to 604800).
Consumers must treat stale state as unavailable rather than current.

Disable this optional endpoint by unsetting `UU_STATUS_API_TOKEN_FILE` and
restarting the Web UI. Existing native interactive auth remains unchanged.

## Acceptance

`python3 tests/test-status-summary-api.py` runs loopback-only HTTP tests
covering authorized/denied requests, stale/unknown counts, partial failures,
missing/invalid status, and disabled configuration. No PVE host is needed.
