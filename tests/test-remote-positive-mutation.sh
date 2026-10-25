#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/jobs" "$WORK_DIR/remote"

write_job_state() {
  local unit="$1"
  cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=928
state=running
started_at=2026-10-25T07:00:00Z
finished_at=
exit_code=
type=update
message=
source=remote
EOF
}

write_update_fixture() {
  local mode="$1"
  cat > "$WORK_DIR/update.sh" <<'UPDATE'
#!/usr/bin/env bash
set -euo pipefail

# The controller's old zero is intentionally still present in the inherited
# environment.  The worker result below is the fresh target-bound observation.
[[ "${UU_UPDATE_PENDING_BEFORE_TARGET:-}" == 928 ]]
[[ "${UU_UPDATE_PENDING_BEFORE:-}" == 0 ]]
case "${FIXTURE_MODE:?}" in
  positive)
    cat > "$UU_STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","reachable":true,"check_status":"ok","updates":{"available":0},"package_checked_at":"2026-10-25T07:00:02Z","package_data_invalidated":false,"package_mutation_in_progress":false,"package_mutation_generation":2,"last_update":{"status":"success","timestamp":"2026-10-25T07:00:02Z","exit_code":0,"pending_before":6}}]}
JSON
    printf '0\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
    ;;
  positive-warning)
    cat > "$UU_STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","reachable":true,"check_status":"ok","updates":{"available":null},"package_data_invalidated":true,"package_mutation_in_progress":false,"package_mutation_generation":2,"last_update":{"status":"success","timestamp":"2026-10-25T07:00:02Z","exit_code":0,"pending_before":6}}]}
JSON
    printf '89\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
    ;;
  noop)
    cat > "$UU_STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","reachable":true,"check_status":"ok","updates":{"available":0},"package_data_invalidated":false,"package_mutation_in_progress":false,"last_update":{"status":"skipped","timestamp":"2026-10-25T07:00:02Z","exit_code":0,"pending_before":0}}]}
JSON
    printf '0\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
    ;;
  unsupported)
    cat > "$UU_STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"vm","node":"Proxmox-Test-2","reachable":true,"check_status":"unsupported","last_update":{"status":"unsupported","timestamp":"2026-10-25T07:00:02Z","exit_code":21}}]}
JSON
    printf '0\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
    ;;
  incomplete)
    rm -f -- "$UU_STATUS_MODEL_FILE" "$UU_REMOTE_WORK_DIR/post-update-status.rc"
    ;;
  *) exit 2 ;;
esac

# The historical controller baseline is deliberately not used as the worker
# result.  The worker status contains the fresh positive baseline above.
exit 10
UPDATE
  chmod 750 "$WORK_DIR/update.sh"
}

run_case() {
  local name="$1" mode="$2" expected_rc="$3" expected_state="$4" expected_exit="$5"
  local unit="ultimate-updater-update-928-$name" rc
  write_job_state "$unit"
  write_update_fixture "$mode"
  rm -f -- "$WORK_DIR/status.json" "$WORK_DIR/remote/post-update-status.rc"
  set +e
  FIXTURE_MODE="$mode" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
    UU_LOCAL_FILES="$WORK_DIR" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
    UU_REMOTE_WORK_DIR="$WORK_DIR/remote" \
    UU_UPDATE_PENDING_BEFORE_TARGET=928 UU_UPDATE_PENDING_BEFORE=0 \
    "$ROOT_DIR/job-runner.sh" run "$unit" 928 "$WORK_DIR/update.sh" \
    >"$WORK_DIR/$name.output" 2>&1
  rc=$?
  set -e
  [[ "$rc" == "$expected_rc" ]]
  grep -Fxq "state=$expected_state" "$WORK_DIR/jobs/$unit.state"
  grep -Fxq "exit_code=$expected_exit" "$WORK_DIR/jobs/$unit.state"
}

# A positive fresh worker result outranks the stale controller zero and is a
# completed job, not a neutral exit-10 skip.
run_case positive positive 0 completed 0
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert result["status"] == "success"
assert result["pending_before"] == 6
PY

# A positive mutation with an incomplete package handback is warning-only, not
# a no-op.  The invalidation remains visible to the controller guards.
run_case positive_warning positive-warning 0 completed_with_warnings 0
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["pending_before"] == 6
assert record["package_data_invalidated"] is True
PY

# Remote handback must preserve a positive mutation when the worker completed
# with warnings; the controller must not project that terminal result as a
# neutral skipped/no-op state.
awk '/^sync_remote_last_update\(\) \{/{capture=1} capture && /^remote_log\(\)/{exit} capture{print}' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/sync-remote.sh"
cat > "$WORK_DIR/handback-warning.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"928","type":"lxc","node":"Proxmox-Test-2","check_status":"ok",
   "reachable":true,"updates":{"available":null},
   "package_data_invalidated":true,"package_mutation_in_progress":false,
   "last_update":{"status":"success","timestamp":"2026-10-25T07:00:02Z",
                   "exit_code":0,"pending_before":6}}
]}
JSON
UU_STATUS_MODEL_FILE="$WORK_DIR/handback-warning.json" \
  bash -c 'source "$1"; sync_remote_last_update 928 completed_with_warnings 2026-10-25T07:00:03Z 0' \
  _ "$WORK_DIR/sync-remote.sh"
python3 - "$WORK_DIR/handback-warning.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "completed_with_warnings"
assert record["last_update"]["pending_before"] == 6
assert record["package_data_invalidated"] is True
PY

# Explicit current no-op and unsupported results retain their neutral job
# semantics.
run_case noop noop 10 skipped 10
run_case unsupported unsupported 10 skipped 10

# An exit-10 worker without a current terminal result is a failed handoff, not
# a fabricated no-op.
run_case incomplete incomplete 1 failed 1

echo 'remote positive mutation result regression: PASS'
