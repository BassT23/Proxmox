#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

write_stale_status() {
  python3 - "$1" <<'PY'
import json, sys
data = {"schema_version": 1, "targets": [
    {"id": "211", "type": "lxc", "transport": "pct", "reachable": True,
     "check_status": "error", "error": {"code": "CHECK_COMMAND_FAILED", "message": "apt-get update failed"},
     "last_update": {"status": "failed", "timestamp": "2026-08-17T05:00:00Z", "exit_code": 1}},
    {"id": "999", "type": "lxc", "transport": "pct", "reachable": True,
     "check_status": "error", "error": {"code": "OLD_ERROR", "message": "old"}},
]}
json.dump(data, open(sys.argv[1], "w", encoding="utf-8"))
PY
}

run_check() {
  local status_file="$1" records_file="$2" partial="$3"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$status_file" \
    STATUS_MODEL_RECORD_FILE="$records_file" STATUS_MODEL_PARTIAL="$partial" bash -c '
      source "$1"
      STATUS_MODEL_INIT
      STATUS_MODEL_RECORD 211 lxc pct false "" "" null null not_checked STOPPED_READ_ONLY \
        "LXC 211 is stopped; initial inventory did not start it" node2 lxc-211
      STATUS_MODEL_FINISH
    ' _ "$ROOT_DIR/status-model.sh"
}

run_imported_check() {
  local status_file="$1" records_file="$2" remote_file="$3"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$status_file" \
    STATUS_MODEL_RECORD_FILE="$records_file" bash -c '
      source "$1"
      STATUS_MODEL_INIT
      STATUS_MODEL_IMPORT_FILE "$2"
      STATUS_MODEL_FINISH
    ' _ "$ROOT_DIR/status-model.sh" "$remote_file"
}

assert_full() {
  python3 - "$1" <<'PY'
import json, sys
targets = {item["id"]: item for item in json.load(open(sys.argv[1]))["targets"]}
assert targets["211"]["check_status"] == "not_checked"
assert targets["211"]["error"] is None
assert targets["211"]["last_update"]["status"] == "failed"
assert "999" not in targets
PY
}

assert_partial() {
  python3 - "$1" <<'PY'
import json, sys
targets = {item["id"]: item for item in json.load(open(sys.argv[1]))["targets"]}
assert targets["211"]["check_status"] == "not_checked"
assert targets["211"]["error"] is None
assert targets["999"]["check_status"] == "error"
PY
}

REMOTE_STATUS="$WORK_DIR/remote-status.json"
python3 - "$REMOTE_STATUS" <<'PY'
import json, sys
json.dump({"targets": [{
    "id": "211", "type": "lxc", "transport": "pct", "reachable": False,
    "check_status": "not_checked",
    "error": {"code": "STOPPED_READ_ONLY", "message": "stopped"},
    "last_update": {"status": "failed", "timestamp": "2026-08-17T05:00:00Z", "exit_code": 1},
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY

IMPORTED_STATUS="$WORK_DIR/imported-status.json"
write_stale_status "$IMPORTED_STATUS"
run_imported_check "$IMPORTED_STATUS" "$WORK_DIR/imported-records" "$REMOTE_STATUS"
assert_full "$IMPORTED_STATUS"

FULL_STATUS="$WORK_DIR/full-status.json"
write_stale_status "$FULL_STATUS"
run_check "$FULL_STATUS" "$WORK_DIR/full-records" false
assert_full "$FULL_STATUS"

PARTIAL_STATUS="$WORK_DIR/partial-status.json"
write_stale_status "$PARTIAL_STATUS"
run_check "$PARTIAL_STATUS" "$WORK_DIR/partial-records" true
assert_partial "$PARTIAL_STATUS"

printf '%s\n' 'status model freshness regression tests: PASS'
