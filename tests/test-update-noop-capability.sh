#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# A successful updater wrapper with no packages pending is a neutral no-op,
# not a successful update result.
cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"115","type":"lxc","node":"node1","updates":{"available":0},"check_status":"ok","last_update":{"status":"unknown"}}
]}
JSON
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT 115 success 0 "" "" "" 0' \
  _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "skipped"
assert record["last_update"]["pending_before"] == 0
PY

# The capability gate only reads Proxmox configuration.  An unmanaged LXC is
# rejected before any guest, lifecycle, backup, or snapshot command can run.
awk '
  /^UPDATE_TARGET_CAPABILITY_PRECHECK\(\) \{/{copy=1}
  /^UPDATE_TARGET_CAPABILITY_GUARD\(\) \{/{if(copy) exit}
  copy
' "$ROOT_DIR/update.sh" > "$WORK_DIR/capability.sh"
cat > "$WORK_DIR/capability-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOG="$PWD/actions.log"
pct() {
  printf 'pct %s\n' "$*" >> "$LOG"
  [[ "$1" == config ]] && printf 'ostype: %s\n' "${OSTYPE_FIXTURE:-unmanaged}"
}
qm() { printf 'qm %s\n' "$*" >> "$LOG"; return 1; }
source "$PWD/capability.sh"
if UPDATE_TARGET_CAPABILITY_PRECHECK 115 lxc; then
  echo 'unsupported LXC unexpectedly passed capability preflight' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 21 ]]
fi
if grep -Eq 'pct (exec|start|snapshot)|qm (start|resume|guest)' "$LOG" 2>/dev/null; then
  echo 'capability preflight performed a mutating or guest action' >&2
  exit 1
fi
OSTYPE_FIXTURE=unknown
if UPDATE_TARGET_CAPABILITY_PRECHECK 115 lxc; then
  echo 'unknown LXC OS unexpectedly passed capability preflight' >&2
  exit 1
else
  rc=$?
  [[ "$rc" == 21 ]]
fi
echo capability-preflight: PASS
HARNESS
chmod 750 "$WORK_DIR/capability-harness.sh"
(cd "$WORK_DIR" && bash capability-harness.sh)

# A neutral update result must remain a skipped job.  It is not a completed
# update and it is not a post-capture warning: no package mutation occurred.
mkdir -p "$WORK_DIR/jobs"
cat > "$WORK_DIR/update-skipped.sh" <<'UPDATE'
#!/usr/bin/env bash
exit 10
UPDATE
chmod 750 "$WORK_DIR/update-skipped.sh"
cat > "$WORK_DIR/jobs/ultimate-updater-update-115-skipped.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-115-skipped
target=115
state=running
started_at=2026-10-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
    "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-115-skipped 115 \
    "$WORK_DIR/update-skipped.sh" >/dev/null 2>&1; then
  skipped_rc=0
else
  skipped_rc=$?
fi
[[ "$skipped_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-115-skipped.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-115-skipped.state"
if grep -Fxq 'state=completed_with_warnings' "$WORK_DIR/jobs/ultimate-updater-update-115-skipped.state"; then
  echo 'neutral update result was exposed as completed_with_warnings' >&2
  exit 1
fi

# The global update aggregate uses the same neutral terminal state.
cat > "$WORK_DIR/jobs/ultimate-updater-update-all-systems-skipped.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-all-systems-skipped
target=all-systems
state=running
started_at=2026-10-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
    "$ROOT_DIR/job-runner.sh" run-global ultimate-updater-update-all-systems-skipped \
    "$WORK_DIR/update-skipped.sh" >/dev/null 2>&1; then
  global_skipped_rc=0
else
  global_skipped_rc=$?
fi
[[ "$global_skipped_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-all-systems-skipped.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-all-systems-skipped.state"

# A failed guest post-capture is a warning terminal state, not completed.
mkdir -p "$WORK_DIR/jobs"
cat > "$WORK_DIR/update.sh" <<'UPDATE'
#!/usr/bin/env bash
printf '89\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
exit 0
UPDATE
chmod 750 "$WORK_DIR/update.sh"
cat > "$WORK_DIR/jobs/ultimate-updater-update-115.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-115
target=115
state=running
started_at=2026-10-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_WORK_DIR="$WORK_DIR" \
  "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-115 115 "$WORK_DIR/update.sh" >/dev/null 2>&1
grep -Fxq 'state=completed_with_warnings' "$WORK_DIR/jobs/ultimate-updater-update-115.state"
grep -Fxq 'exit_code=0' "$WORK_DIR/jobs/ultimate-updater-update-115.state"

echo 'update no-op and capability regressions: PASS'
