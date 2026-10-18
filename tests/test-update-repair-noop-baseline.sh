#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Use the production handoff and repair functions, while replacing all
# transport/package commands with deterministic local fixtures.
awk '/^CAPTURE_UPDATE_PENDING_BEFORE\(\) \{/{capture=1} capture{print} capture && /^}\s*$/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/capture.sh"
awk '/^RECORD_UPDATE_RESULT\(\) \{/{capture=1} capture{print} capture && /^}\s*$/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/result.sh"
awk '/^UPDATE_FINAL_RC\(\) \{/{capture=1} capture{print} capture && /^}\s*$/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/final-rc.sh"
awk '/^DPKG_REPAIR_PREPARE\(\) \{/{capture=1} capture{print} capture && /^}\s*$/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/repair.sh"
awk '/^CAPTURE_REMOTE_UPDATE_PENDING_BEFORE\(\) \{/{capture=1} capture{print} capture && /^}\s*$/{exit}' \
  "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/remote-capture.sh"

cat > "$WORK_DIR/status-model-input.json" <<'JSON'
{"schema_version":1,"targets":[]}
JSON

run_worker_result() {
  local baseline_target="$1" baseline_value="$2" expected_status="$3" expected_exit="$4" expected_final_rc="$5"
  # A remote update workspace starts without a status file; invalidation
  # creates the exact target record before the worker performs its repair.
  rm -f -- "$WORK_DIR/status.json"
  set +e
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
    UU_UPDATE_PENDING_BEFORE_TARGET="$baseline_target" \
    UU_UPDATE_PENDING_BEFORE="$baseline_value" \
    bash -c '
      set -u
      declare -A UPDATE_PENDING_BEFORE=()
      source "$1"
      source "$2"
      source "$3"
      source "$4"
      source "$5"
      UPDATE_FAILURE=false
      UPDATE_WARNING=false
      SAFETY_FAILURE=false
      REMOTE_TARGET_DISPATCHED=false
      DPKG_REPAIR_TIMEOUT=120
      DPKG_REPAIR_CHECKED=()
      DPKG_REPAIR_ERROR=""
      STATUS_MODEL_INVALIDATE_PACKAGE_DATA 928 lxc node2 uu-op-test-20261018-00000000
      mock_audit_calls=0
      mock_repair_calls=0
      mock_apt_calls=0
      mock_runner() {
        case "$1" in
          audit)
            mock_audit_calls=$((mock_audit_calls + 1))
            [[ "$mock_audit_calls" -eq 1 ]] && printf "dpkg interrupted\n"
            return 0
            ;;
          repair)
            mock_repair_calls=$((mock_repair_calls + 1))
            return 0
            ;;
          *) return 2 ;;
        esac
      }
      DPKG_REPAIR_PREPARE lxc:928 "LXC 928" mock_runner
      [[ "$mock_repair_calls" -eq 1 ]]
      [[ "$mock_audit_calls" -eq 2 ]]
      RECORD_UPDATE_RESULT 928 success 0
      [[ "$UPDATE_WARNING" == true ]]
      [[ "$mock_apt_calls" -eq 0 ]]
      set +e
      UPDATE_FINAL_RC 0
      final_rc=$?
      set -e
      [[ "$final_rc" == "$6" ]]
      STATUS_MODEL_COMPLETE_PACKAGE_MUTATION 928 lxc node2 uu-op-test-20261018-00000000
    ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/capture.sh" "$WORK_DIR/result.sh" "$WORK_DIR/repair.sh" "$WORK_DIR/final-rc.sh" "$expected_final_rc"
  result=$?
  set -e
  python3 - "$WORK_DIR/status.json" "$expected_status" "$expected_exit" <<'PY'
import json
import sys

path, expected_status, expected_exit = sys.argv[1:]
payload = json.load(open(path, encoding="utf-8"))
record = payload["targets"][0]
result = record["last_update"]
assert result["status"] == expected_status, result
assert str(result["exit_code"]) == expected_exit, result
if expected_status == "skipped":
    assert result["pending_before"] == 0
    assert record["package_mutation_in_progress"] is False
PY
  [[ "$result" -eq 0 ]]
}

# The remote worker starts with an empty status model.  A controller-provided
# zero baseline survives the repair and produces the required no-op result.
run_worker_result 928 0 skipped 0 10

# Positive baselines still prove a real update path; they must not be changed
# into a no-op merely because the repair ran first.
run_worker_result 928 2 success 0 0

# Missing and malformed controller handoff values remain fail-closed.
cp "$WORK_DIR/status-model-input.json" "$WORK_DIR/status.json"
set +e
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'declare -A UPDATE_PENDING_BEFORE=(); source "$1"; source "$2"; source "$3"; UPDATE_FAILURE=false; RECORD_UPDATE_RESULT 928 success 0' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/capture.sh" "$WORK_DIR/result.sh" >/dev/null 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" -eq 96 ]]
grep -Fq PENDING_BEFORE_UNAVAILABLE "$WORK_DIR/status.json" || {
  echo "missing baseline was not recorded as unavailable" >&2
  exit 1
}

cp "$WORK_DIR/status-model-input.json" "$WORK_DIR/status.json"
set +e
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  UU_UPDATE_PENDING_BEFORE_TARGET=928 UU_UPDATE_PENDING_BEFORE=invalid \
  bash -c 'declare -A UPDATE_PENDING_BEFORE=(); source "$1"; source "$2"; source "$3"; UPDATE_FAILURE=false; RECORD_UPDATE_RESULT 928 success 0' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/capture.sh" "$WORK_DIR/result.sh" >/dev/null 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 97 ]]
grep -Fq PENDING_BEFORE_INVALID "$WORK_DIR/status.json" || {
  echo "invalid baseline was not recorded as invalid" >&2
  exit 1
}

# A failed repair must stop before the package-manager continuation point.
source "$WORK_DIR/repair.sh"
APT_AUTO_REPAIR_DPKG=true
declare -A DPKG_REPAIR_CHECKED=()
DPKG_REPAIR_ERROR=""
apt_calls=0
failed_repair_runner() {
  case "$1" in
    audit) printf 'dpkg interrupted\n' ;;
    repair) return 1 ;;
    *) return 2 ;;
  esac
}
set +e
DPKG_REPAIR_PREPARE lxc:928 "LXC 928" failed_repair_runner
repair_rc=$?
set -e
if [[ "$repair_rc" -eq 0 ]]; then
  echo "failed repair unexpectedly continued" >&2
  exit 1
fi
[[ "$DPKG_REPAIR_ERROR" == DPKG_REPAIR_FAILED ]]
[[ "$apt_calls" -eq 0 ]]

# The controller-side capture is identity- and freshness-bound. A current
# package observation may provide zero, while an old or incomplete record
# must not be converted into a synthetic no-op baseline.
python3 - "$WORK_DIR/controller-status.json" "$WORK_DIR/controller-status-stale.json" <<'PY'
import json
import sys
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
fresh = now.isoformat(timespec="microseconds").replace("+00:00", "Z")
stale = (now - timedelta(days=2)).isoformat(timespec="microseconds").replace("+00:00", "Z")

def record(identifier, kind, node, available, checked_at):
    return {
        "id": identifier, "type": kind, "node": node, "reachable": True,
        "check_status": "ok", "updates": {"available": available},
        "last_check": checked_at, "package_checked_at": checked_at,
        "package_data_invalidated": False,
        "package_mutation_in_progress": False,
    }

payload = {"schema_version": 1, "targets": [
    record("928", "lxc", "Proxmox-Test-2", 0, fresh),
    record("929", "vm", "Proxmox-Test-2", 4, fresh),
]}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(payload, output)
stale_payload = {"schema_version": 1, "targets": [
    record("928", "lxc", "Proxmox-Test-2", 0, stale),
]}
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(stale_payload, output)
PY
python3 - "$WORK_DIR/controller-status-newer-update.json" <<'PY'
import json
import sys
from datetime import datetime, timezone

checked = (datetime.now(timezone.utc)).isoformat(timespec="microseconds").replace("+00:00", "Z")
record = {
    "id": "928", "type": "lxc", "node": "Proxmox-Test-2", "reachable": True,
    "check_status": "ok", "updates": {"available": 0},
    "last_check": checked, "package_checked_at": checked,
    "last_update": {"status": "success", "timestamp": checked},
}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"schema_version": 1, "targets": [record]}, output)
PY
STATUS_FILE="$WORK_DIR/controller-status.json"
source "$WORK_DIR/remote-capture.sh"
LOCAL_FILES="$WORK_DIR"
source "$ROOT_DIR/status-model.sh"
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 928 lxc Proxmox-Test-2
[[ "$REMOTE_UPDATE_PENDING_TARGET" == 928 ]]
[[ "$REMOTE_UPDATE_PENDING_BEFORE" == 0 ]]
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 929 vm Proxmox-Test-2
[[ "$REMOTE_UPDATE_PENDING_BEFORE" == 4 ]]

# A stale baseline is unavailable, not a valid zero baseline.
STATUS_FILE="$WORK_DIR/controller-status-stale.json"
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 928 lxc Proxmox-Test-2
[[ -z "$REMOTE_UPDATE_PENDING_BEFORE" ]]

# A legacy record with a newer non-neutral update result is also stale even
# when both stored observation timestamps are otherwise recent.
STATUS_FILE="$WORK_DIR/controller-status-newer-update.json"
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 928 lxc Proxmox-Test-2
[[ -z "$REMOTE_UPDATE_PENDING_BEFORE" ]]

# The local capture uses the same guard and therefore cannot bypass it.
declare -A UPDATE_PENDING_BEFORE=()
STATUS_MODEL_FILE="$WORK_DIR/controller-status.json"
source "$WORK_DIR/capture.sh"
CAPTURE_UPDATE_PENDING_BEFORE 928
[[ "${UPDATE_PENDING_BEFORE[928]}" == 0 ]]
UPDATE_PENDING_BEFORE=()
STATUS_MODEL_FILE="$WORK_DIR/controller-status-stale.json"
CAPTURE_UPDATE_PENDING_BEFORE 928
[[ -z "${UPDATE_PENDING_BEFORE[928]}" ]]

# Missing timestamps remain unavailable even when the numeric count is zero.
cat > "$WORK_DIR/controller-status-missing-timestamp.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","reachable":true,"check_status":"ok","updates":{"available":0}}]}
JSON
STATUS_FILE="$WORK_DIR/controller-status-missing-timestamp.json"
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 928 lxc Proxmox-Test-2
[[ -z "$REMOTE_UPDATE_PENDING_BEFORE" ]]

STATUS_FILE="$WORK_DIR/controller-status.json"
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 928 vm Proxmox-Test-2
[[ -z "$REMOTE_UPDATE_PENDING_BEFORE" ]]
CAPTURE_REMOTE_UPDATE_PENDING_BEFORE 929 vm wrong-node
[[ -z "$REMOTE_UPDATE_PENDING_BEFORE" ]]

# Static assertions ensure the value crosses both the remote dispatch and
# systemd job boundary, including an empty/invalid value for fail-closed use.
grep -Fq 'UU_UPDATE_PENDING_BEFORE_TARGET' "$ROOT_DIR/update.sh"
grep -Fq 'UU_UPDATE_PENDING_BEFORE_TARGET' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_UPDATE_PENDING_BEFORE_TARGET' "$ROOT_DIR/job-runner.sh"

echo 'repair-only/no-op baseline handoff regression: PASS'
