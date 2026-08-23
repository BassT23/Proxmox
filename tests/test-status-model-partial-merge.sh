#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"1","type":"vm","check_status":"ok","reachable":true,"updates":{"available":1}},
  {"id":"2","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":2}},
  {"id":"3","type":"vm","check_status":"error","reachable":true,"updates":{"available":9}},
  {"id":"4","type":"vm","check_status":"ok","reachable":true,"updates":{"available":4}},
  {"id":"5","type":"external","check_status":"ok","reachable":true,"updates":{"available":5}}
]}
JSON

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 3 vm qga true debian apt 0 false ok "" "" node3 vm-3 0 0
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"

python3 - "$WORK_DIR/status.json" <<'PY'
import json, sys
targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert set(targets) == {"1", "2", "3", "4", "5"}
assert targets["3"]["check_status"] == "ok"
assert targets["3"]["updates"]["available"] == 0
assert targets["1"]["updates"]["available"] == 1
assert targets["2"]["updates"]["available"] == 2
assert targets["4"]["updates"]["available"] == 4
assert targets["5"]["updates"]["available"] == 5
PY

cp "$WORK_DIR/status.json" "$WORK_DIR/before-invalid.json"
printf 'not-a-valid-record\n' > "$WORK_DIR/records"
if LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" 2>/dev/null; then
  echo 'invalid partial capture unexpectedly succeeded' >&2
  exit 1
fi
cmp -s "$WORK_DIR/before-invalid.json" "$WORK_DIR/status.json"

echo 'status model partial merge regression tests: PASS'
