#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"a","type":"vm","check_status":"ok","reachable":true,"updates":{"available":1},"last_check":"2026-09-10T02:00:00Z"},
  {"id":"b","type":"vm","check_status":"ok","reachable":true,"updates":{"available":2},"last_check":"2026-09-10T02:00:00Z"},
  {"id":"old","type":"vm","check_status":"ok","reachable":true,"updates":{"available":3}}
]}
JSON

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert set(targets) == {"a", "b", "old"}
assert targets["a"]["last_check"] == "2026-09-10T02:00:00Z"
assert targets["b"]["last_check"] == "2026-09-10T02:00:00Z"
PY

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/success.records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD b vm qga true debian apt 0 false ok "" "" node1 guest-b 0 0
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/failure.records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD b vm qga true debian apt null null error CHECK_COMMAND_FAILED "apt-get update failed" node1 guest-b
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert set(targets) == {"a", "b", "old"}
assert targets["a"]["last_check"] == "2026-09-10T02:00:00Z"
assert targets["b"]["check_status"] == "error"
assert targets["b"]["error"]["code"] == "CHECK_COMMAND_FAILED"
PY

grep -Fq 'CHECK all systems failed: No targets were checked.' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_MODEL_MARK_ZERO_TARGETS' "$ROOT_DIR/check-updates.sh"
grep -Fq 'targets checked' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_FILE}.zero-target' "$ROOT_DIR/ultimate-updater"
echo 'status model zero-target safety tests: PASS'
