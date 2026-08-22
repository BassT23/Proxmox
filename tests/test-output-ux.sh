#!/bin/bash

set -euo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin"

cat > "$WORK_DIR/status.json" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-01-01T00:00:00Z",
  "targets": [
    {"id":"host:Proxmox-Test-1","type":"host","name":"Proxmox-Test-1","reachable":true,"updates":{"available":0},"check_status":"ok","last_check":"2026-01-01T00:00:00Z"},
    {"id":"910","type":"lxc","name":"debian12","reachable":true,"updates":{"available":0},"check_status":"ok","last_check":"2026-01-01T00:00:00Z"}
  ]
}
JSON

cat > "$WORK_DIR/job-runner.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  list)
    printf 'ultimate-updater-check-910-20260101-000000-1\t910\tcompleted\tstart\tend\t0\tcheck\n'
    printf 'ultimate-updater-update-910-20260101-000001-2\t910\tfailed\tstart\tend\t17\tupdate\n'
    ;;
  start-check)
    printf 'Running as unit: ultimate-updater-check-910-20260101-000002-3.service\n'
    printf 'Check job started\nTarget: 910\nJob: ultimate-updater-check-910-20260101-000002-3\n'
    printf 'Status: ultimate-updater status\nLogs: journalctl -u ultimate-updater-check-910-20260101-000002-3\n'
    ;;
  *)
    printf 'unexpected job-runner action: %s\n' "${1:-}" >&2
    exit 2
    ;;
esac
SH
chmod +x "$WORK_DIR/job-runner.sh"

status_output=$(UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/ultimate-updater" status)
diff -u "$ROOT_DIR/tests/golden/status-jobs.txt" <(printf '%s\n' "$status_output")
grep -Fq 'Jobs' <<<"$status_output"
if grep -Fq 'Update jobs' <<<"$status_output"; then exit 1; fi
grep -Fq 'CHECK' <<<"$status_output"
grep -Fq 'UPDATE' <<<"$status_output"
grep -Fq '910 · debian12' <<<"$status_output"

cat > "$WORK_DIR/bin/pct" <<'SH'
#!/bin/bash
[[ "${1:-}" == config && "${2:-}" == 910 ]]
SH
chmod +x "$WORK_DIR/bin/pct"

cat > "$WORK_DIR/check-updates.sh" <<'SH'
#!/bin/bash
cat > "$UU_LOCAL_FILES/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"910","type":"lxc","name":"debian12","reachable":true,"updates":{"available":0},"check_status":"ok"}]}
JSON
SH
chmod +x "$WORK_DIR/check-updates.sh"

start_output=$(PATH="$WORK_DIR/bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/ultimate-updater" check 910)
grep -Fq 'Check job started' <<<"$start_output"
grep -Fq 'Target: 910' <<<"$start_output"

# The job runner owns the public asynchronous entry point. Exercise the
# internal execution path explicitly when asserting the completed-check
# summary, just as systemd does through run-check.
check_output=$(PATH="$WORK_DIR/bin:$PATH" UU_CHECK_JOB_EXECUTION=true UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/ultimate-updater" check 910)
diff -u "$ROOT_DIR/tests/golden/check-no-updates.txt" <(printf '%s\n' "$check_output")
grep -Fq '0 updates available' <<<"$check_output"

for golden in "$ROOT_DIR"/tests/golden/*.txt; do
  if grep -Pq $'\033\\[[0-9;]*[A-Za-z]' "$golden"; then exit 1; fi
  awk 'length($0) <= 160 { next } { exit 1 }' "$golden"
done

if grep -Fq 'Update jobs' "$ROOT_DIR/web-ui/server.py" &&
   ! grep -Fq 'PAGE = PAGE.replace("Update jobs", "Jobs")' "$ROOT_DIR/web-ui/server.py"; then
  printf 'legacy jobs heading is not normalized\n' >&2
  exit 1
fi

printf 'output UX golden tests: PASS\n'
