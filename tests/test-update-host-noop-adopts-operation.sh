#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
# A node worker started by a cluster controller with a reserved operation ID
# (UU_PACKAGE_MUTATION_OPERATION_ID) must carry that operation through its host
# record even when the host has nothing to update.  The controller only clears
# its invalidation of the node from a result with the same operation ID, so a
# no-op worker that skipped the reservation left the node invalidated on the
# controller for good.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
HOST_NODE=$(hostname -s 2>/dev/null || hostname)
OPERATION_ID=uu-op-20261121T120000000000000-4242-1234

# Mock host check: like check-updates.sh it merges a fresh, valid observation
# with 0 pending into the existing host record (operation and generation are
# kept) and clears an invalidation only when no mutation is in progress.
cat > "$WORK_DIR/check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CHECK_LOG"
python3 - "$STATUS_MODEL_FILE" "$STATUS_MODEL_NODE" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

path, node = sys.argv[1:]
try:
    payload = json.load(open(path, encoding="utf-8"))
except FileNotFoundError:
    payload = {"schema_version": 1, "targets": []}
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
record = next((t for t in payload["targets"] if t.get("id") == f"host:{node}"), None)
if record is None:
    record = {"id": f"host:{node}", "type": "host", "node": node,
              "package_data_invalidated": False, "package_mutation_in_progress": False}
    payload["targets"].append(record)
record.update({"reachable": True, "check_status": "ok", "updates": {"available": 0},
               "last_check": now, "package_checked_at": now})
if not record.get("package_mutation_in_progress"):
    record["package_data_invalidated"] = False
    record.pop("package_data_invalidated_at", None)
json.dump(payload, open(path + ".tmp", "w", encoding="utf-8"))
os.replace(path + ".tmp", path)
PY
CHECK
chmod 750 "$WORK_DIR/check.sh"

# Production functions: preflight, intentional skip, the reservation helpers
# and UPDATE_HOST_ITSELF itself.
awk '/^HOST_UPDATE_TARGET_ID\(\) \{/{copy=1} /^# A stopped guest/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/functions.sh"
awk '/^MARK_PACKAGE_DATA_INVALIDATED\(\) \{/{copy=1} /^CLEAR_PACKAGE_MUTATION_RESERVATIONS\(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"
awk '/^UPDATE_HOST_ITSELF \(\) \{/{copy=1} copy{print} copy && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
MODE=$3            # with-operation | with-operation-no-welcome | without-operation
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
export CHECK_LOG="$WORK_DIR/check.log"
: > "$CHECK_LOG"
WELCOME_SCREEN=false
case "$MODE" in
  with-operation) export UU_PACKAGE_MUTATION_OPERATION_ID="$OPERATION_ID"; WELCOME_SCREEN=true ;;
  with-operation-no-welcome) export UU_PACKAGE_MUTATION_OPERATION_ID="$OPERATION_ID" ;;
  *) unset UU_PACKAGE_MUTATION_OPERATION_ID ;;
esac

cat > "$STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[]}
JSON
: > "$WORK_DIR/events"

declare -A UPDATE_PENDING_BEFORE=()
declare -A PACKAGE_MUTATION_KEYS=()
declare -A PACKAGE_MUTATION_OPERATIONS=()
declare -a PACKAGE_MUTATION_TARGETS=()
UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_RESULT_RECORDED=false
UPDATE_WARNING_RC=10
ERROR_CODE=""
HOSTNAME="$STATUS_MODEL_NODE"
INCLUDE_PHASED_UPDATES=false
DPKG_OPTIONS=()
APT_COMMAND=apt-get
CHOST=""

EFFECTIVE_HEADLESS() { return 0; }
DPKG_REPAIR_PREPARE() { printf '%s\n' repair >> "$WORK_DIR/events"; return 0; }
pveupdate() { printf '%s\n' pveupdate >> "$WORK_DIR/events"; return 0; }
RUN_UPDATE_COMMAND() { printf 'mutate %s\n' "$*" >> "$WORK_DIR/events"; return 0; }
# Stands in for the post-update check: like the real check-updates.sh it may
# only clear the invalidation of a record whose reservation was completed.
UPDATE_CHECK() {
  printf 'post-check chost=%s\n' "$CHOST" >> "$WORK_DIR/events"
  python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import os
import sys

path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
record = payload["targets"][0]
assert record["package_mutation_in_progress"] is False, record
record["package_data_invalidated"] = False
record.pop("package_data_invalidated_at", None)
json.dump(payload, open(path + ".tmp", "w", encoding="utf-8"))
os.replace(path + ".tmp", path)
PY
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
REQUIRE_PACKAGE_DATA_INVALIDATION() { printf '%s\n' invalidate-gate >> "$WORK_DIR/events"; return 0; }
# Log the reservation lifecycle around the production helpers.
eval "$(declare -f MARK_PACKAGE_DATA_INVALIDATED | sed '1s/^/REAL_/')"
eval "$(declare -f MARK_PACKAGE_DATA_MUTATION_COMPLETE | sed '1s/^/REAL_/')"
MARK_PACKAGE_DATA_INVALIDATED() { printf 'invalidate %s\n' "$*" >> "$WORK_DIR/events"; REAL_MARK_PACKAGE_DATA_INVALIDATED "$@"; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { printf 'complete %s\n' "$*" >> "$WORK_DIR/events"; REAL_MARK_PACKAGE_DATA_MUTATION_COMPLETE "$@"; }

if UPDATE_HOST_ITSELF; then rc=0; else rc=$?; fi
printf 'rc=%s failure=%s recorded=%s\n' "$rc" "$UPDATE_FAILURE" "$UPDATE_RESULT_RECORDED" > "$WORK_DIR/result"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

run_case() {
  local mode=$1
  rm -rf -- "$WORK_DIR/case-$mode"
  mkdir -p -- "$WORK_DIR/case-$mode"
  cp "$WORK_DIR/check.sh" "$WORK_DIR/functions.sh" "$WORK_DIR/harness.sh" "$WORK_DIR/case-$mode/"
  OPERATION_ID=$OPERATION_ID bash "$WORK_DIR/case-$mode/harness.sh" "$ROOT_DIR" \
    "$WORK_DIR/case-$mode" "$mode" > "$WORK_DIR/case-$mode/output" 2>&1 || {
      cat "$WORK_DIR/case-$mode/output" >&2
      return 1
    }
}

assert_no_mutation() {
  if grep -Eq 'pveupdate|mutate ' "$1"; then
    printf 'unexpected host mutation in %s\n' "$1" >&2
    return 1
  fi
}

# Worker of a controller reservation: the host record ends up carrying the
# controller's operation, with the reservation completed and no invalidation.
run_case with-operation
grep -Fq 'rc=0 failure=false recorded=true' "$WORK_DIR/case-with-operation/result"
assert_no_mutation "$WORK_DIR/case-with-operation/events"
python3 - "$WORK_DIR/case-with-operation" "$HOST_NODE" "$OPERATION_ID" <<'PY'
import json
import sys

case, node, operation = sys.argv[1:]
events = [line.strip() for line in open(f"{case}/events", encoding="utf-8")]
invalidate = next(i for i, line in enumerate(events) if line.startswith("invalidate "))
complete = next(i for i, line in enumerate(events) if line.startswith("complete "))
post_check = next(i for i, line in enumerate(events) if line.startswith("post-check"))
assert invalidate < complete < post_check, events
assert "post-check chost=true" in events, events
record = json.load(open(f"{case}/status.json", encoding="utf-8"))["targets"][0]
assert record["package_mutation_operation_id"] == operation, record
assert record["package_mutation_in_progress"] is False, record
assert record["package_data_invalidated"] is False, record
assert record["last_update"]["status"] == "skipped", record
assert record["last_update"]["exit_code"] == 10, record
assert record["last_update"]["skip_reason"]["code"] == "NO_UPDATES_AVAILABLE", record
PY

# Same without the welcome screen: UPDATE_CHECK would not refresh anything, so
# the host check runs again after the reservation and clears the invalidation.
run_case with-operation-no-welcome
grep -Fq 'rc=0 failure=false recorded=true' "$WORK_DIR/case-with-operation-no-welcome/result"
assert_no_mutation "$WORK_DIR/case-with-operation-no-welcome/events"
python3 - "$WORK_DIR/case-with-operation-no-welcome" "$OPERATION_ID" <<'PY'
import json
import sys

case, operation = sys.argv[1:]
events = [line.strip() for line in open(f"{case}/events", encoding="utf-8")]
assert not any(line.startswith("post-check") for line in events), events
invalidate = next(i for i, line in enumerate(events) if line.startswith("invalidate "))
complete = next(i for i, line in enumerate(events) if line.startswith("complete "))
assert invalidate < complete, events
checks = [line for line in open(f"{case}/check.log", encoding="utf-8") if line.strip()]
assert len(checks) == 2, checks
record = json.load(open(f"{case}/status.json", encoding="utf-8"))["targets"][0]
assert record["package_mutation_operation_id"] == operation, record
assert record["package_mutation_in_progress"] is False, record
assert record["package_data_invalidated"] is False, record
assert record["last_update"]["status"] == "skipped", record
assert record["last_update"]["exit_code"] == 10, record
PY

# Direct run (no controller operation): unchanged, no reservation lifecycle.
run_case without-operation
grep -Fq 'rc=0 failure=false recorded=true' "$WORK_DIR/case-without-operation/result"
assert_no_mutation "$WORK_DIR/case-without-operation/events"
if grep -Eq '^(invalidate|complete|post-check)' "$WORK_DIR/case-without-operation/events"; then
  printf 'direct no-op run must not reserve the host\n' >&2
  exit 1
fi
python3 - "$WORK_DIR/case-without-operation/status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert "package_mutation_operation_id" not in record, record
assert record["last_update"]["status"] == "skipped", record
PY

printf '%s\n' 'host no-op adopts controller operation regression: PASS'
