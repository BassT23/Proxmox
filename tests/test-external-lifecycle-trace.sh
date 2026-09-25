#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat >"$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"generated_at":"2026-09-25T16:00:00Z","targets":[
  {"id":"ext01","type":"external","check_status":"ok","reachable":true,
   "updates":{"available":1},"last_update":{"status":"unknown","timestamp":null}}
]}
JSON

trace() {
  local enabled="$1" trace_file="$2" checkpoint="$3" rc="${4:-}"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
    UU_EXTERNAL_LIFECYCLE_TRACE="$enabled" \
    UU_EXTERNAL_LIFECYCLE_TRACE_FILE="$trace_file" \
    bash -c 'source "$1"; STATUS_MODEL_TRACE_EVENT "$2" ext01 "$3"' \
    _ "$ROOT_DIR/status-model.sh" "$checkpoint" "$rc"
}

OFF_TRACE="$WORK_DIR/off.jsonl"
trace false "$OFF_TRACE" disabled
[[ ! -e "$OFF_TRACE" ]]

ON_TRACE="$WORK_DIR/on.jsonl"
trace true "$ON_TRACE" external_before_update
trace true "$ON_TRACE" external_result_write_rc 0
trace true "$ON_TRACE" external_after_result_write
[[ $(wc -l <"$ON_TRACE") -eq 3 ]]

python3 - "$ON_TRACE" "$WORK_DIR/status.json" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
assert [event["checkpoint"] for event in events] == [
    "external_before_update", "external_result_write_rc", "external_after_result_write"
]
assert all(event["target_id"] == "ext01" for event in events)
assert events[1]["helper_rc"] == 0
assert all("password" not in json.dumps(event).lower() for event in events)
status = json.load(open(sys.argv[2], encoding="utf-8"))
assert status["targets"][0]["last_update"]["status"] == "unknown"
PY

BAD_TRACE="$WORK_DIR/missing/trace.jsonl"
if trace true "$BAD_TRACE" trace_failure; then
  :
fi
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
record = payload["targets"][0]
assert record["last_update"]["status"] == "unknown"
assert record["updates"]["available"] == 1
PY

echo 'External lifecycle trace regression: PASS'
