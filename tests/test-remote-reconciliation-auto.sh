#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
REMOTE_DIR=$(mktemp -d /tmp/ultimate-updater-auto-reconcile-XXXXXX)
trap 'rm -rf -- "$WORK_DIR" "$REMOTE_DIR"' EXIT

mkdir -p "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
printf '%s\n' '{"schema_version":1,"generated_at":"2026-10-18T15:00:00Z","targets":[{"id":"986","type":"lxc","node":"test-node2","name":"fixture","check_status":"ok","reachable":true,"updates":{"available":0},"package_data_invalidated":true,"package_mutation_in_progress":true,"last_update":{"status":"old"}}]}' > "$WORK_DIR/status.json"
touch "$WORK_DIR/update.conf"

cat > "$WORK_DIR/status-model.sh" <<'EOF'
#!/usr/bin/env bash
STATUS_MODEL_VALIDATE_TARGET_FILE() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
targets = payload.get("targets", [])
raise SystemExit(0 if any(str(item.get("id")) == sys.argv[2] for item in targets)
                 else 1)
PY
}
EOF
chmod 750 "$WORK_DIR/status-model.sh"

cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == status-import && $# -eq 2 ]] || exit 2
printf '%s\n' "$2" >> "$IMPORT_LOG"
cp -- "$2" "$UU_STATUS_MODEL_FILE"
EOF
chmod 750 "$WORK_DIR/check.sh"

cat > "$WORK_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SSH_DOWN:-false}" != true ]] || exit 1
bash -c "${!#}"
EOF
chmod 750 "$WORK_DIR/bin/ssh"
export PATH="$WORK_DIR/bin:$PATH"

make_remote_job() {
  local unit="$1" state="$2" exit_code="$3"
  cat > "$WORK_DIR/jobs/remote/$unit.ref" <<EOF
schema_version=1
unit=$unit
target=986
owner_node=test-node2
owner_host=127.0.0.1
port=22
registered_at=2026-10-18T15:01:00Z
status_refresh=pending
workspace=$REMOTE_DIR/$unit
EOF
  mkdir -p "$REMOTE_DIR/$unit"
  {
    printf 'schema_version=1\nunit=%s\ntarget=986\nstate=%s\n' "$unit" "$state"
    printf 'started_at=2026-10-18T15:01:00Z\nfinished_at=%s\n' \
      "$([[ "$state" == running ]] && printf '' || printf '2026-10-18T15:02:00Z')"
    printf 'exit_code=%s\ntype=update\nmessage=fixture\nsource=remote\ninteractive=false\n' "$exit_code"
  } > "$WORK_DIR/jobs/remote/$unit.state"
  printf '%s\n' '{"schema_version":1,"generated_at":"2026-10-18T15:02:00Z","targets":[{"id":"986","type":"lxc","node":"test-node2","name":"fixture","check_status":"ok","reachable":true,"updates":{"available":0},"package_data_invalidated":false,"package_mutation_generation":3,"package_mutation_in_progress":false,"package_mutation_operation_id":"uu-op-fixture","package_checked_at":"2026-10-18T15:02:00Z","packages":[],"last_update":{"status":"success","timestamp":"2026-10-18T15:02:00Z","exit_code":0,"pending_before":6}}]}' > "$REMOTE_DIR/$unit/status.json"
}

run_status() {
  UU_LOCAL_FILES="$WORK_DIR" \
  UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" \
  UU_CHECK_CLI="$WORK_DIR/check.sh" \
  UU_CHECK_SCRIPT="$WORK_DIR/check.sh" \
  UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  IMPORT_LOG="$WORK_DIR/import.log" \
  "$ROOT_DIR/ultimate-updater" status --json > "$WORK_DIR/status-output"
}

: > "$WORK_DIR/import.log"
make_remote_job ultimate-updater-update-986-auto completed 0
run_status
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-auto.ref"
grep -Fq '"package_data_invalidated":false' "$WORK_DIR/status-output"
grep -Fq '"package_mutation_in_progress":false' "$WORK_DIR/status-output"
python3 - "$WORK_DIR/status-output" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["pending_before"] == 6
PY
[[ $(wc -l < "$WORK_DIR/import.log") -eq 1 ]]
test ! -e "$REMOTE_DIR/ultimate-updater-update-986-auto"

# A second normal status read is idempotent and must not import twice.
run_status
[[ $(wc -l < "$WORK_DIR/import.log") -eq 1 ]]

# A running remote job remains pending and does not trigger a capture import.
make_remote_job ultimate-updater-update-986-running running ''
run_status
grep -Fxq 'status_refresh=pending' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-running.ref"
test -e "$REMOTE_DIR/ultimate-updater-update-986-running"
[[ $(wc -l < "$WORK_DIR/import.log") -eq 1 ]]

# A temporary transport failure remains retryable and succeeds on the next
# normal status poll after transport is restored.
make_remote_job ultimate-updater-update-986-retry completed 0
SSH_DOWN=true run_status
grep -Fxq 'status_refresh=pending' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-retry.ref"
test -e "$REMOTE_DIR/ultimate-updater-update-986-retry"
[[ $(wc -l < "$WORK_DIR/import.log") -eq 1 ]]
run_status
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-retry.ref"
[[ $(wc -l < "$WORK_DIR/import.log") -eq 2 ]]

# The explicit command remains safe and idempotent after automatic refresh.
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" \
  UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" \
  UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  IMPORT_LOG="$WORK_DIR/import.log" "$ROOT_DIR/job-runner.sh" reconcile-remote \
  ultimate-updater-update-986-retry >/dev/null
[[ $(wc -l < "$WORK_DIR/import.log") -eq 2 ]]

# API v1 status retains the existing reconciliation trigger.  The two summary
# endpoints are pure status.json projections and must not start a worker.
python3 - "$ROOT_DIR" <<'PY'
import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile

root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as temporary:
    status_file = Path(temporary) / "status.json"
    status_file.write_text(json.dumps({
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "targets": [{"id": "986", "type": "lxc", "check_status": "ok",
                     "reachable": True, "updates": {"available": 0}}],
    }), encoding="utf-8")
    handler = object.__new__(module.StatusHandler)
    calls = []
    responses = []
    handler.schedule_remote_reconciliation = lambda: calls.append("schedule")
    handler.send_json = lambda payload, status=200: responses.append((payload, status))
    handler.server = SimpleNamespace(
        status_file=status_file,
        status_api_max_age_seconds=86400,
        package_freshness_max_age_seconds=86400,
    )
    handler._api_v1_status()
    handler._api_v1_status_summary()
    handler.handle_status_summary()
    assert calls == ["schedule"], calls
    assert len(responses) == 1, responses

print("remote reconciliation auto-trigger tests: PASS")
PY

echo 'remote reconciliation automatic polling: PASS'
