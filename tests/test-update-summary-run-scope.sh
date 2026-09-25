#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat >"$WORK_DIR/baseline.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"guest:201","type":"lxc","updates":{"available":5}},
  {"id":"external:e2e-ext","type":"external","updates":{"available":1}},
  {"id":"guest:202","type":"lxc","updates":{"available":0}}
]}
JSON

cat >"$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"guest:201","type":"lxc","node":"node2","name":"updated","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-25T16:00:01Z","exit_code":0,"pending_before":0}},
  {"id":"external:e2e-ext","type":"external","name":"e2e-ext","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-25T16:00:02Z","exit_code":0,"pending_before":0}},
  {"id":"guest:202","type":"lxc","node":"node1","name":"current","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-25T16:00:03Z","exit_code":0}},
  {"id":"host:old","type":"host","node":"old","name":"old","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-23T11:00:00Z","exit_code":0,"pending_before":5}}
]}
JSON

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_APPLY_PRE_UPDATE_COUNTS "$2" 2026-09-25T16:00:00Z' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/baseline.json"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert targets["guest:201"]["last_update"]["pending_before"] == 5
assert targets["external:e2e-ext"]["last_update"]["pending_before"] == 1
assert targets["guest:202"]["last_update"]["pending_before"] == 0
assert targets["host:old"]["last_update"]["pending_before"] == 5
PY

LOCAL_FILES="$WORK_DIR" bash -c \
  'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update "" "" 2026-09-25T16:00:00Z' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" >"$WORK_DIR/current.txt"

grep -Fq 'updated' "$WORK_DIR/current.txt"
grep -Fq 'e2e-ext' "$WORK_DIR/current.txt"
grep -Fq 'Successfully updated' "$WORK_DIR/current.txt"
grep -Fq 'Up to date' "$WORK_DIR/current.txt"
grep -Fq 'old' "$WORK_DIR/current.txt"
grep -Fq 'Result unavailable' "$WORK_DIR/current.txt"
if grep -A1 -F 'old' "$WORK_DIR/current.txt" | grep -Fq 'Successfully updated'; then
  echo 'historical result was rendered as current work' >&2
  exit 1
fi

cat >"$WORK_DIR/legacy.json" <<'JSON'
{"targets":[{"id":"guest:legacy","type":"lxc","name":"legacy","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-25T16:00:04Z","exit_code":0}}]}
JSON
LOCAL_FILES="$WORK_DIR" bash -c \
  'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update "" "" 2026-09-25T16:00:00Z' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/legacy.json" | grep -Fq 'Successfully updated'

echo 'update summary run-scope regression: PASS'
