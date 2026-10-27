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
cat > "$WORK_DIR/status-skipped.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"115","type":"lxc","check_status":"ok","reachable":true,
   "updates":{"available":0},"package_data_invalidated":false,
   "package_mutation_in_progress":false,
   "last_update":{"status":"skipped","timestamp":"2026-10-18T00:00:01Z","exit_code":0,"pending_before":0}}
]}
JSON
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
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-skipped.json" \
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

# An explicit transport skip is a current terminal result even without a
# package baseline. It carries a stable reason and remains neutral in the
# target runner.
cat > "$WORK_DIR/status-no-transport.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"fixture-vm","type":"vm","check_status":"ok","last_update":{"status":"unknown"}}]}
JSON
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status-no-transport.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT fixture-vm skipped 10 "" "" "" "" NO_SUPPORTED_TRANSPORT "No usable QGA or SSH transport is configured."' \
  _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/status-no-transport.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert result["status"] == "skipped"
assert result["exit_code"] == 10
assert result["skip_reason"] == {
    "code": "NO_SUPPORTED_TRANSPORT",
    "message": "No usable QGA or SSH transport is configured.",
}
assert "pending_before" not in result
PY
cat > "$WORK_DIR/update-no-transport.sh" <<'UPDATE'
#!/usr/bin/env bash
exit 10
UPDATE
chmod 750 "$WORK_DIR/update-no-transport.sh"
cat > "$WORK_DIR/jobs/ultimate-updater-update-fixture-vm-no-transport.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-fixture-vm-no-transport
target=fixture-vm
state=running
started_at=2026-10-25T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-no-transport.json" \
    "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-fixture-vm-no-transport fixture-vm \
    "$WORK_DIR/update-no-transport.sh" >/dev/null 2>&1; then
  transport_skip_rc=0
else
  transport_skip_rc=$?
fi
[[ "$transport_skip_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-fixture-vm-no-transport.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-fixture-vm-no-transport.state"
if grep -Fq 'no update lifecycle was started' "$WORK_DIR/jobs/ultimate-updater-update-fixture-vm-no-transport.state"; then
  echo 'transport skip retained the old lifecycle failure message' >&2
  exit 1
fi

# The old no-confirmed-mutation sentence is reserved for genuine warning
# output, never for a neutral exit-10 result.
awk '/^UPDATE_MAIL_BODY\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-mail-body.sh"
: > "$WORK_DIR/update.log"
: > "$WORK_DIR/errors.log"
neutral_mail=$(LOG_FILE="$WORK_DIR/update.log" ERROR_LOG_FILE="$WORK_DIR/errors.log" \
  SINGLE_UPDATE=true EXIT_CODE=10 UPDATE_WARNING_REAL=false HOSTNAME=fixture \
  ID=fixture-vm NAME=fixture VM=fixture-vm bash -c 'source "$1"; UPDATE_MAIL_BODY' _ "$WORK_DIR/update-mail-body.sh")
grep -Fq 'Update skipped; no package mutation was required.' <<< "$neutral_mail"
if grep -Fq 'completed with warnings' <<< "$neutral_mail"; then
  echo 'neutral exit 10 was rendered as a warning' >&2
  exit 1
fi
warning_mail=$(LOG_FILE="$WORK_DIR/update.log" ERROR_LOG_FILE="$WORK_DIR/errors.log" \
  SINGLE_UPDATE=true EXIT_CODE=10 UPDATE_WARNING_REAL=true HOSTNAME=fixture \
  ID=fixture-vm NAME=fixture VM=fixture-vm bash -c 'source "$1"; UPDATE_MAIL_BODY' _ "$WORK_DIR/update-mail-body.sh")
grep -Fq 'Update completed with warnings' <<< "$warning_mail"

# Exercise the real VM inventory/update selection function with a VM that has
# neither QGA nor an enabled Internal SSH profile. No lifecycle command may
# be reached, and an explicit target must not fall through to the old generic
# "no update lifecycle was started" failure.
awk '/^RECORD_INTENTIONAL_SKIP\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/intentional-skip.sh"
awk '/^VM_UPDATE_START \(\) \{/{copy=1} copy{print} copy && /^# Detect the Proxmox guest OS/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/vm-update-start.sh"
cat > "$WORK_DIR/vm-skip-harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOCAL_FILES="$PWD"
STATUS_MODEL_FILE="$PWD/status-vm.json"
SINGLE_UPDATE=true ONLY=fixture-vm EXCLUDED="" USE_INTERNAL_TARGET_SELECTION=false
STOPPED_VM=false RUNNING_VM=true UPDATE_WARNING_RC=10
UPDATE_FAILURE=false UPDATE_WARNING=false UPDATE_RESULT_RECORDED=false
SINGLE_TARGET_EXECUTED=false
declare -A UPDATE_PENDING_BEFORE=([fixture-vm]=5)
qm() {
  case "$1" in
    list) printf 'VMID NAME STATUS\nfixture-vm fixture running\n' ;;
    config) printf 'name: fixture\nostype: l26\n' ;;
    start|resume|shutdown|stop) printf 'unexpected lifecycle: %s\n' "$*" >&2; return 1 ;;
  esac
}
QGA_CONFIG_ENABLED() { return 1; }
INTERNAL_SSH_TARGET_STATE() { return 1; }
guest_id_matches() { return 1; }
source "$PWD/status-model.sh"
source "$PWD/intentional-skip.sh"
source "$PWD/vm-update-start.sh"
VM_UPDATE_START
[[ "$SINGLE_TARGET_EXECUTED" == true ]]
[[ "$UPDATE_FAILURE" == false ]]
HARNESS
chmod 750 "$WORK_DIR/vm-skip-harness.sh"
cat > "$WORK_DIR/status-vm.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"fixture-vm","type":"vm","node":"node1","check_status":"ok","last_update":{"status":"unknown"}}]}
JSON
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/status-model.sh"
(cd "$WORK_DIR" && bash vm-skip-harness.sh)
python3 - "$WORK_DIR/status-vm.json" <<'PY'
import json
import sys

result = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert result["status"] == "skipped"
assert result["exit_code"] == 10
assert result["skip_reason"]["code"] == "NO_SUPPORTED_TRANSPORT"
PY

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
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-skipped.json" \
    "$ROOT_DIR/job-runner.sh" run-global ultimate-updater-update-all-systems-skipped \
    "$WORK_DIR/update-skipped.sh" >/dev/null 2>&1; then
  global_skipped_rc=0
else
  global_skipped_rc=$?
fi
[[ "$global_skipped_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-all-systems-skipped.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-all-systems-skipped.state"

# An explicit unsupported target is also a neutral job result, even when the
# child updater returns its target-level code instead of normalizing it first.
cat > "$WORK_DIR/status-unsupported.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"108","type":"vm","check_status":"unsupported","last_update":{"status":"unsupported","timestamp":"2026-10-25T12:00:00Z","exit_code":21}}]}
JSON
cat > "$WORK_DIR/update-unsupported.sh" <<'UPDATE'
#!/usr/bin/env bash
exit 21
UPDATE
chmod 750 "$WORK_DIR/update-unsupported.sh"
cat > "$WORK_DIR/jobs/ultimate-updater-update-108-unsupported.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-108-unsupported
target=108
state=running
started_at=2026-10-25T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-unsupported.json" \
    "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-108-unsupported 108 \
    "$WORK_DIR/update-unsupported.sh" >/dev/null 2>&1; then
  unsupported_rc=0
else
  unsupported_rc=$?
fi
[[ "$unsupported_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-108-unsupported.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-108-unsupported.state"

cat > "$WORK_DIR/status-unsupported-115.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"115","type":"unknown","check_status":"unsupported","last_update":{"status":"unsupported","timestamp":"2026-10-25T12:00:00Z","exit_code":21}}]}
JSON
cat > "$WORK_DIR/jobs/ultimate-updater-update-115-unsupported.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-115-unsupported
target=115
state=running
started_at=2026-10-25T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-unsupported-115.json" \
    "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-115-unsupported 115 \
    "$WORK_DIR/update-unsupported.sh" >/dev/null 2>&1; then
  unsupported_115_rc=0
else
  unsupported_115_rc=$?
fi
[[ "$unsupported_115_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-115-unsupported.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-115-unsupported.state"

cat > "$WORK_DIR/jobs/ultimate-updater-update-all-unsupported.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-all-unsupported
target=all-systems
state=running
started_at=2026-10-25T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-unsupported.json" \
    "$ROOT_DIR/job-runner.sh" run-global ultimate-updater-update-all-unsupported \
    "$WORK_DIR/update-unsupported.sh" >/dev/null 2>&1; then
  global_unsupported_rc=0
else
  global_unsupported_rc=$?
fi
[[ "$global_unsupported_rc" -eq 10 ]]
grep -Fxq 'state=skipped' "$WORK_DIR/jobs/ultimate-updater-update-all-unsupported.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/ultimate-updater-update-all-unsupported.state"

# Exit 21 without an explicit current unsupported result remains a technical
# failure and must not be converted into a neutral job state.
cat > "$WORK_DIR/update-unsupported-failure.sh" <<'UPDATE'
#!/usr/bin/env bash
exit 21
UPDATE
chmod 750 "$WORK_DIR/update-unsupported-failure.sh"
cat > "$WORK_DIR/status-failed.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"108","type":"vm","check_status":"error","last_update":{"status":"failed","timestamp":"2026-10-25T12:00:00Z","exit_code":21}}]}
JSON
cat > "$WORK_DIR/jobs/ultimate-updater-update-108-failure.state" <<'STATE'
schema_version=1
unit=ultimate-updater-update-108-failure
target=108
state=running
started_at=2026-10-25T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
STATE
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/status-failed.json" \
    "$ROOT_DIR/job-runner.sh" run ultimate-updater-update-108-failure 108 \
    "$WORK_DIR/update-unsupported-failure.sh" >/dev/null 2>&1; then
  echo 'technical exit 21 was incorrectly skipped' >&2
  exit 1
else
  technical_rc=$?
fi
[[ "$technical_rc" -eq 21 ]]
grep -Fxq 'state=failed' "$WORK_DIR/jobs/ultimate-updater-update-108-failure.state"

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
