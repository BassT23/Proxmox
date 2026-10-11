#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
REMOTE_DIR=$(mktemp -d /tmp/ultimate-updater-update-node-test-XXXXXX)
trap 'rm -rf -- "$WORK_DIR" "$REMOTE_DIR"' EXIT
mkdir -p "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
printf '%s\n' '{"schema_version":1,"targets":[{"id":"986","last_update":{"status":"old","exit_code":99}}]}' > "$WORK_DIR/status.json"
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
raise SystemExit(0 if any(str(item.get("id")) == sys.argv[2] for item in targets) else 1)
PY
}
EOF
chmod 755 "$WORK_DIR/status-model.sh"

cat > "$WORK_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SSH_DOWN:-false}" != true ]] || exit 1
bash -c "${!#}"
EOF
chmod 755 "$WORK_DIR/bin/ssh"
export PATH="$WORK_DIR/bin:$PATH"

cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == status-import && $# -eq 2 ]] || exit 2
cp -- "$2" "$UU_STATUS_MODEL_FILE"
EOF
chmod 755 "$WORK_DIR/check.sh"

make_remote_job() {
  local unit="$1" state="$2" exit_code="$3" status="$4"
  cat > "$WORK_DIR/jobs/remote/$unit.ref" <<EOF
schema_version=1
unit=$unit
target=986
owner_node=test-node1
owner_host=127.0.0.1
port=22
registered_at=2026-10-11T09:11:52Z
status_refresh=pending
workspace=$REMOTE_DIR/$unit
EOF
  mkdir -p "$REMOTE_DIR/$unit"
  {
    printf 'schema_version=1\nunit=%s\ntarget=986\nstate=%s\n' "$unit" "$state"
    printf 'started_at=2026-10-11T09:11:52Z\nfinished_at=2026-10-11T09:13:44Z\n'
    printf 'exit_code=%s\ntype=update\nmessage=test\nsource=\nguest_job_id=\ninteractive=false\n' "$exit_code"
  } > "$WORK_DIR/jobs/remote/$unit.state"
  printf '{"schema_version":1,"targets":[{"id":"986","last_update":{"status":"%s","timestamp":"2026-10-11T09:13:44Z","exit_code":%s},"reachable":true,"updates":{"available":0},"reboot_required":false}]}\n' "$status" "${exit_code:-0}" > "$REMOTE_DIR/$unit/status.json"
}

make_remote_job ultimate-updater-update-986-reconcile completed 0 success
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  "$ROOT_DIR/job-runner.sh" list > "$WORK_DIR/list-success"
grep -Fq $'ultimate-updater-update-986-reconcile\t986\tcompleted' "$WORK_DIR/list-success"
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-reconcile.ref"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"success"' "$WORK_DIR/status.json"
test ! -e "$REMOTE_DIR/ultimate-updater-update-986-reconcile"
rm -f "$WORK_DIR/jobs/remote/ultimate-updater-update-986-reconcile.ref" "$WORK_DIR/jobs/remote/ultimate-updater-update-986-reconcile.state"

# A terminal remote failure is still successfully reconciled.
make_remote_job ultimate-updater-update-986-failed failed 7 failed
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  "$ROOT_DIR/job-runner.sh" list >/dev/null
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-failed.ref"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"failed"' "$WORK_DIR/status.json"
grep -Eq '"exit_code"[[:space:]]*:[[:space:]]*7' "$WORK_DIR/status.json"
rm -f "$WORK_DIR/jobs/remote/ultimate-updater-update-986-failed.ref" "$WORK_DIR/jobs/remote/ultimate-updater-update-986-failed.state"

# A transport failure remains pending and can be reconciled later.
make_remote_job ultimate-updater-update-986-retry completed 0 success
SSH_DOWN=true UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  "$ROOT_DIR/job-runner.sh" list >/dev/null
grep -Fxq 'status_refresh=pending' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-retry.ref"
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  "$ROOT_DIR/job-runner.sh" list >/dev/null
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-retry.ref"

# Running jobs are not imported or restarted.
make_remote_job ultimate-updater-update-986-running running '' success
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" UU_LOCAL_FILES="$WORK_DIR" UU_CHECK_CLI="$WORK_DIR/check.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" \
  "$ROOT_DIR/job-runner.sh" list >/dev/null
grep -Fxq 'status_refresh=pending' "$WORK_DIR/jobs/remote/ultimate-updater-update-986-running.ref"

echo 'remote status reconciliation tests: PASS'
