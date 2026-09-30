#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"guest:5","type":"lxc","node":"node1","name":"updated","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":5}},
  {"id":"guest:1","type":"vm","node":"node1","name":"updated-one","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":1}},
  {"id":"guest:0","type":"lxc","node":"node1","name":"current","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":0}},
  {"id":"guest:unknown","type":"lxc","node":"node1","name":"unknown-before","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success"}},
  {"id":"guest:failed","type":"lxc","node":"node1","name":"failed","check_status":"error","reachable":true,"updates":{"available":0},"last_update":{"status":"failed","exit_code":42,"pending_before":2}},
  {"id":"guest:reboot","type":"lxc","node":"node1","name":"reboot","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":true,"last_update":{"status":"success","pending_before":1}},
  {"id":"external-linux","type":"external","name":"ext01","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":3}}
]}
JSON

LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/rendered.txt"

grep -Fq 'Successfully updated' "$WORK_DIR/rendered.txt"
[[ $(grep -Fc '   Successfully updated' "$WORK_DIR/rendered.txt") -eq 4 ]]
grep -Fq '   Up to date' "$WORK_DIR/rendered.txt"
grep -Fq '   Update failed' "$WORK_DIR/rendered.txt"
grep -Fq 'Updated – reboot required' "$WORK_DIR/rendered.txt"
grep -Fq 'ext01' "$WORK_DIR/rendered.txt"
[[ $(grep -Fc 'Guests:' "$WORK_DIR/rendered.txt") -eq 1 ]]

# A legacy success result without pending_before is intentionally treated as
# work completed rather than falsely inferred to be up to date.
grep -Fq '🐧  unknown-before' "$WORK_DIR/rendered.txt" ||
  grep -Fq 'unknown-before' "$WORK_DIR/rendered.txt"

# STATUS_MODEL_UPDATE_RESULT captures the pre-update count in the result.
cat > "$WORK_DIR/write-status.json" <<'JSON'
{"targets":[{"id":"ext01","type":"external","updates":{"available":5},"last_update":{"status":"unknown"}}]}
JSON
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/write-status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT ext01 success 0' \
  _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/write-status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["pending_before"] == 5
PY

# Imported remote results retain the new metadata through STATUS_MODEL_FINISH.
cat > "$WORK_DIR/remote-status.json" <<'JSON'
{"targets":[{"id":"201","type":"lxc","node":"node2","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-25T10:00:00Z","exit_code":0,"pending_before":5}}]}
JSON
printf '%s\n' '{"schema_version":1,"targets":[{"id":"201","type":"lxc","node":"node2","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}}]}' > "$WORK_DIR/import-status.json"
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/import-status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/import.records" bash -c \
  'source "$1"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/remote-status.json"
python3 - "$WORK_DIR/import-status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["pending_before"] == 5
PY

echo 'update summary pending-before regression: PASS'
