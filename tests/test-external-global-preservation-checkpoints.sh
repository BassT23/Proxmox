#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"ext01","type":"external","name":"ext01","os":"Debian","check_status":"ok","reachable":true,"updates":{"available":2},"reboot_required":false,"last_update":{"status":"unknown","timestamp":null,"exit_code":null}}
]}
JSON

status_value() {
  python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys
item = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
print(item["last_update"]["status"])
PY
}

# Checkpoint 1: external-apt's successful update result reaches status.json.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT ext01 success 0' \
  _ "$ROOT_DIR/status-model.sh"
[[ "$(status_value)" == success ]]
echo "EXTERNAL_AFTER_UPDATE_STATUS=$(status_value)"

# Checkpoint 2: the update-result snapshot retains the success.
cp "$WORK_DIR/status.json" "$WORK_DIR/snapshot.json"
python3 - "$WORK_DIR/snapshot.json" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]["last_update"]["status"] == "success"
PY
echo "EXTERNAL_SNAPSHOT_STATUS=$(status_value)"
echo "EXTERNAL_AFTER_REMOTE_COLLECTION_STATUS=$(status_value)"

# Checkpoint 3: the fresh observation replaces the transient update result.
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
payload["targets"][0]["last_update"] = {"status": "unknown", "timestamp": None, "exit_code": None}
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output)
    output.write("\n")
PY
echo "EXTERNAL_AFTER_FULL_REFRESH_STATUS=$(status_value)"

# Checkpoint 4: current-run preservation restores only the matching fresh
# external record, and the renderer consumes that final model.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_PRESERVE_UPDATE_RESULTS "$2" "2026-09-23T00:00:00Z"' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/snapshot.json"
[[ "$(status_value)" == success ]]
echo "EXTERNAL_AFTER_PRESERVE_STATUS=$(status_value)"

LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/rendered.txt"
grep -Fq 'ext01' "$WORK_DIR/rendered.txt"
echo "EXTERNAL_FINAL_RENDER_STATUS=$(status_value)"
echo 'external global preservation checkpoint regression: PASS'
