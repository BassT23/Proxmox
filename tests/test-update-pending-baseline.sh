#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"901","type":"lxc","check_status":"ok","reachable":true,"updates":{},"last_update":{"status":"unknown"}},
  {"id":"902","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}},
  {"id":"903","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}},
  {"id":"904","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}},
  {"id":"905","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}},
  {"id":"906","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}}
]}
JSON

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; UPDATE_FAILURE=false; STATUS_MODEL_UPDATE_RESULT "$2" success 0 || rc=$?; [[ "${rc:-0}" == 96 && "$UPDATE_FAILURE" == true ]]' \
  _ "$ROOT_DIR/status-model.sh" 901 >"$WORK_DIR/missing.log" 2>&1
grep -Fq 'PENDING_BEFORE_UNAVAILABLE' "$WORK_DIR/missing.log"

if LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT "$2" success 0 "" "" "" invalid' \
  _ "$ROOT_DIR/status-model.sh" 902 >"$WORK_DIR/invalid.log" 2>&1; then
  echo 'invalid pending_before unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'PENDING_BEFORE_INVALID' "$WORK_DIR/invalid.log"

# A real mutation with an explicit positive baseline remains successful.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT "$2" success 0 "" "" 2 2' \
  _ "$ROOT_DIR/status-model.sh" 903

# A valid no-op remains skipped with the neutral exit code 10 at target level.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT "$2" success 0 "" "" "" 0' \
  _ "$ROOT_DIR/status-model.sh" 904

# completed_with_warnings is valid only with the same explicit mutation
# baseline. Missing provenance is converted to a failed result instead.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT "$2" completed_with_warnings 0 "" "" "" 3' \
  _ "$ROOT_DIR/status-model.sh" 905
if LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT "$2" completed_with_warnings 0' \
  _ "$ROOT_DIR/status-model.sh" 906 >"$WORK_DIR/warning.log" 2>&1; then
  echo 'warning result without pending_before unexpectedly succeeded' >&2
  exit 1
fi

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = {str(item["id"]): item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert targets["901"]["last_update"]["status"] == "failed"
assert targets["901"]["last_update"]["exit_code"] == 96
assert "pending_before" not in targets["901"]["last_update"]
assert "PENDING_BEFORE_UNAVAILABLE" in targets["901"]["last_update"]["message"]
assert targets["902"]["last_update"]["status"] == "failed"
assert targets["902"]["last_update"]["exit_code"] == 97
assert "pending_before" not in targets["902"]["last_update"]
assert "PENDING_BEFORE_INVALID" in targets["902"]["last_update"]["message"]
assert targets["903"]["last_update"]["status"] == "success"
assert targets["903"]["last_update"]["pending_before"] == 2
assert targets["904"]["last_update"]["status"] == "skipped"
assert targets["904"]["last_update"]["exit_code"] == 10
assert targets["904"]["last_update"]["pending_before"] == 0
assert targets["904"]["last_update"]["skip_reason"]["code"] == "NO_UPDATES_AVAILABLE"
assert targets["905"]["last_update"]["status"] == "completed_with_warnings"
assert targets["905"]["last_update"]["pending_before"] == 3
assert targets["906"]["last_update"]["status"] == "failed"
assert targets["906"]["last_update"]["exit_code"] == 96
PY

cat > "$WORK_DIR/render-status.json" <<'JSON'
{"targets":[
  {"id":"907","type":"lxc","name":"missing-baseline","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T00:00:01Z","processed":4}},
  {"id":"908","type":"lxc","name":"warning-missing-baseline","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"completed_with_warnings","timestamp":"2026-10-18T00:00:02Z","processed":4}},
  {"id":"909","type":"lxc","name":"valid-update","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T00:00:03Z","pending_before":2,"updated_packages":2}}
]}
JSON
LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update "" "" 2026-10-18T00:00:00Z' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/render-status.json" > "$WORK_DIR/rendered.log"
grep -Fq 'Result unavailable' "$WORK_DIR/rendered.log"
if grep -Fq 'Successfully updated' "$WORK_DIR/rendered.log" ||
   grep -Fq 'Update completed with warnings' "$WORK_DIR/rendered.log"; then
  echo 'missing pending_before was rendered as an update success/warning' >&2
  exit 1
fi
grep -Fq '2 packages updated' "$WORK_DIR/rendered.log"

# A terminal remote handback must not synthesize success when its imported
# result has no explicit pending_before baseline.
awk '/^sync_remote_last_update\(\) \{/{capture=1} capture && /^remote_log\(\)/{exit} capture{print}' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/sync-remote.sh"
cat > "$WORK_DIR/remote-sync-status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"910","type":"lxc","node":"node2","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T00:00:01Z","processed":3}}
]}
JSON
if UU_STATUS_MODEL_FILE="$WORK_DIR/remote-sync-status.json" \
  bash -c 'source "$1"; sync_remote_last_update 910 completed 2026-10-18T00:00:02Z 0' \
  _ "$WORK_DIR/sync-remote.sh"; then
  echo 'remote handback without pending_before unexpectedly succeeded' >&2
  exit 1
fi
python3 - "$WORK_DIR/remote-sync-status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "failed"
assert record["last_update"]["exit_code"] == 96
assert "PENDING_BEFORE_UNAVAILABLE" in record["last_update"]["message"]
PY

cat > "$WORK_DIR/remote-sync-noop-status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"911","type":"lxc","node":"node2","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T00:00:01Z","pending_before":0}}
]}
JSON
UU_STATUS_MODEL_FILE="$WORK_DIR/remote-sync-noop-status.json" \
  bash -c 'source "$1"; sync_remote_last_update 911 completed 2026-10-18T00:00:02Z 0' \
  _ "$WORK_DIR/sync-remote.sh"
python3 - "$WORK_DIR/remote-sync-noop-status.json" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["last_update"]["status"] == "skipped"
assert record["last_update"]["exit_code"] == 10
assert record["last_update"]["pending_before"] == 0
PY

echo 'update pending-before fail-closed regression: PASS'
