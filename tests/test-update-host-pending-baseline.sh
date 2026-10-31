#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
HOST_NODE=$(hostname -s 2>/dev/null || hostname)

# Keep this fixture local: the check command is a mock and no package or host
# command is invoked.  It deliberately writes the same status shape as the
# target-bound host check so the production baseline validator is exercised.
cat > "$WORK_DIR/check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "$*" "${STATUS_MODEL_NODE:-}" >> "$CHECK_LOG"
now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
case "${CHECK_MODE:-positive}" in
  positive) status=updates_available; available=3; checked_at="$now" ;;
  noop) status=ok; available=0; checked_at="$now" ;;
  check-failed)
    cat > "$STATUS_MODEL_FILE" <<JSON
{"schema_version":1,"targets":[{"id":"host:${STATUS_MODEL_NODE}","type":"host","node":"${STATUS_MODEL_NODE}","reachable":false,"check_status":"error","updates":{"available":null},"last_check":"$now","package_checked_at":"$now"}]}
JSON
    exit 23
    ;;
  invalid) status=ok; available='"not-a-number"'; checked_at="$now" ;;
  stale) status=ok; available=2; checked_at=2020-01-01T00:00:00Z ;;
  missing) printf '%s\n' '{"schema_version":1,"targets":[]}' > "$STATUS_MODEL_FILE"; exit 0 ;;
  *) exit 24 ;;
esac
cat > "$STATUS_MODEL_FILE" <<JSON
{"schema_version":1,"targets":[{"id":"host:${STATUS_MODEL_NODE}","type":"host","node":"${STATUS_MODEL_NODE}","reachable":true,"check_status":"$status","updates":{"available":$available},"last_check":"$checked_at","package_checked_at":"$checked_at","package_data_invalidated":false,"package_mutation_in_progress":false}]}
JSON
CHECK
chmod 750 "$WORK_DIR/check.sh"

# Extract only the production functions under test.  The status model remains
# the real local implementation, while all mutating commands are mocked below.
awk '/^HOST_UPDATE_TARGET_ID\(\) \{/{copy=1} /^# A stopped guest/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/functions.sh"
awk '/^RECORD_INTENTIONAL_SKIP\(\) \{/{copy=1} /^# Read-only capability gate/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"
awk '/^UPDATE_HOST_ITSELF \(\) \{/{copy=1} copy{print} copy && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
MODE=$3
export CHECK_MODE=$MODE
export CHECK_LOG="$WORK_DIR/check.log"
export LOCAL_FILES="$WORK_DIR/local"
export TEMP_STATE_DIR="$WORK_DIR/temp"
export CHECK_SCRIPT="$WORK_DIR/check.sh"
export STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
export STATUS_MODEL_RECORD_FILE="$WORK_DIR/records"
export STATUS_MODEL_GENERATION_FILE="$WORK_DIR/generations"
export STATUS_MODEL_DIAGNOSTICS_FILE="$WORK_DIR/diagnostics"
export STATUS_MODEL_NODE="$(hostname -s 2>/dev/null || hostname)"
export CONFIG_FILE="$WORK_DIR/update.conf"
mkdir -p "$LOCAL_FILES" "$TEMP_STATE_DIR"

cat > "$STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"host:fixture-host","type":"host","node":"fixture-host","reachable":true,"check_status":"ok","updates":{"available":0},"last_check":"2026-01-01T00:00:00Z","package_checked_at":"2026-01-01T00:00:00Z","package_data_invalidated":false,"package_mutation_in_progress":false}]}
JSON
: > "$CHECK_LOG"
: > "$WORK_DIR/events"

declare -A UPDATE_PENDING_BEFORE=()
UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_RESULT_RECORDED=false
UPDATE_WARNING_RC=10
ERROR_CODE=""
HOSTNAME="$STATUS_MODEL_NODE"
INCLUDE_PHASED_UPDATES=false
DPKG_OPTIONS=()
APT_COMMAND=apt-get

EFFECTIVE_HEADLESS() { return 0; }
REQUIRE_PACKAGE_DATA_INVALIDATION() { printf '%s\n' invalidate-gate >> "$WORK_DIR/events"; return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { printf 'invalidate %s\n' "$*" >> "$WORK_DIR/events"; return 0; }
DPKG_REPAIR_PREPARE() { printf '%s\n' repair >> "$WORK_DIR/events"; return 0; }
pveupdate() { printf '%s\n' pveupdate >> "$WORK_DIR/events"; return 0; }
RUN_UPDATE_COMMAND() { printf 'mutate %s\n' "$*" >> "$WORK_DIR/events"; return 0; }
UPDATE_CHECK() {
  RECORD_UPDATE_RESULT "$(HOST_UPDATE_TARGET_ID)" success 0
}
RECORD_UPDATE_RESULT() {
  local target=$1 status=$2 rc=${3:-0}
  STATUS_MODEL_UPDATE_RESULT "$target" "$status" "$rc" "" "" "" \
    "${UPDATE_PENDING_BEFORE[$target]-}"
  local result=$?
  [[ "$result" -eq 0 ]] && UPDATE_RESULT_RECORDED=true
  return "$result"
}

source "$ROOT_DIR/status-model.sh"
source "$WORK_DIR/functions.sh"

if [[ "$MODE" == missing-helper ]]; then
  CHECK_SCRIPT="$WORK_DIR/not-present.sh"
fi

if UPDATE_HOST_ITSELF; then
  rc=0
else
  rc=$?
fi
printf 'rc=%s failure=%s pending=%s\n' "$rc" "$UPDATE_FAILURE" \
  "${UPDATE_PENDING_BEFORE[$(HOST_UPDATE_TARGET_ID)]-}" > "$WORK_DIR/result"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

run_case() {
  local mode="$1"
  rm -rf -- "$WORK_DIR/case-$mode"
  mkdir -p -- "$WORK_DIR/case-$mode"
  cp "$WORK_DIR/check.sh" "$WORK_DIR/case-$mode/check.sh"
  cp "$WORK_DIR/functions.sh" "$WORK_DIR/case-$mode/functions.sh"
  cp "$WORK_DIR/harness.sh" "$WORK_DIR/case-$mode/harness.sh"
  CHECK_LOG="$WORK_DIR/case-$mode/check.log" \
    bash "$WORK_DIR/case-$mode/harness.sh" "$ROOT_DIR" \
      "$WORK_DIR/case-$mode" "$mode" >"$WORK_DIR/case-$mode/output" 2>&1 || true
}

assert_no_mutation() {
  local event_file="$1"
  if grep -Eq 'pveupdate|mutate ' "$event_file"; then
    printf 'unexpected host mutation in %s\n' "$event_file" >&2
    return 1
  fi
}

run_case missing-helper
grep -Fq 'PENDING_BEFORE_UNAVAILABLE' "$WORK_DIR/case-missing-helper/output"
assert_no_mutation "$WORK_DIR/case-missing-helper/events"

run_case check-failed
grep -Fq 'PENDING_BEFORE_UNAVAILABLE' "$WORK_DIR/case-check-failed/output"
python3 - "$WORK_DIR/case-check-failed/status.json" <<'PY'
import json
import sys

last_update = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert last_update["status"] == "failed"
assert last_update["exit_code"] == 96
assert "PENDING_BEFORE_UNAVAILABLE" in last_update["message"]
PY
assert_no_mutation "$WORK_DIR/case-check-failed/events"

run_case invalid
grep -Fq 'PENDING_BEFORE_INVALID' "$WORK_DIR/case-invalid/output"
python3 - "$WORK_DIR/case-invalid/status.json" <<'PY'
import json
import sys

last_update = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert last_update["status"] == "failed"
assert last_update["exit_code"] == 97
assert "PENDING_BEFORE_INVALID" in last_update["message"]
PY
assert_no_mutation "$WORK_DIR/case-invalid/events"

run_case stale
grep -Fq 'PENDING_BEFORE_INVALID' "$WORK_DIR/case-stale/output"
python3 - "$WORK_DIR/case-stale/status.json" <<'PY'
import json
import sys

last_update = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]
assert last_update["status"] == "failed"
assert last_update["exit_code"] == 97
assert "PENDING_BEFORE_INVALID" in last_update["message"]
PY
assert_no_mutation "$WORK_DIR/case-stale/events"

run_case positive
grep -Fq -- "-u chost|$HOST_NODE" "$WORK_DIR/case-positive/check.log"
grep -Fq pveupdate "$WORK_DIR/case-positive/events"
grep -Fq 'mutate APT_COMMAND' "$WORK_DIR/case-positive/events"
python3 - "$WORK_DIR/case-positive/status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "success"
assert record["last_update"]["pending_before"] == 3
PY

run_case noop
grep -Fq 'skip_reason' "$WORK_DIR/case-noop/status.json"
python3 - "$WORK_DIR/case-noop/status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "skipped"
assert record["last_update"]["exit_code"] == 10
assert record["last_update"]["pending_before"] == 0
assert record["last_update"]["skip_reason"]["code"] == "NO_UPDATES_AVAILABLE"
PY
assert_no_mutation "$WORK_DIR/case-noop/events"

run_case missing
grep -Fq 'PENDING_BEFORE_UNAVAILABLE' "$WORK_DIR/case-missing/output"
assert_no_mutation "$WORK_DIR/case-missing/events"

printf '%s\n' 'host update pending-before preflight regression: PASS'
