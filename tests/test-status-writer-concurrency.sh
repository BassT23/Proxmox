#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_ROOT=${UU_TEST_ROOT_DIR:-$ROOT_DIR}
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^sync_remote_last_update\(\) \{/{capture=1} capture && /^remote_log\(\)/{exit} capture{print}' \
  "$SOURCE_ROOT/job-runner.sh" > "$WORK_DIR/sync.sh"

cat > "$WORK_DIR/sitecustomize.py" <<'PY'
import os
import time

_replace = os.replace

def replace(source, destination):
    watched = os.environ.get("UU_TEST_PAUSE_DESTINATION")
    if watched and os.path.abspath(destination) == os.path.abspath(watched):
        open(os.environ["UU_TEST_READY"], "w", encoding="utf-8").close()
        while not os.path.exists(os.environ["UU_TEST_RELEASE"]):
            time.sleep(0.01)
    return _replace(source, destination)

os.replace = replace
PY

write_status() {
  local file="$1"
  cat > "$file" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"ext01","type":"external","transport":"ssh","reachable":true,"updates":{"available":5},"last_update":{"status":"unknown","timestamp":null}},
  {"id":"201","type":"lxc","node":"node2","reachable":true,"updates":{"available":1},"last_update":{"status":"unknown","timestamp":null}},
  {"id":"202","type":"vm","node":"node2","reachable":true,"updates":{"available":1},"last_update":{"status":"unknown","timestamp":null}}
]}
JSON
}

assert_results() {
  python3 - "$@" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    targets = {item["id"]: item for item in json.load(source)["targets"]}
for target_id in sys.argv[2:]:
    print(target_id, targets[target_id]["last_update"])
    assert targets[target_id]["last_update"]["status"] == "success"
PY
}

run_sync() {
  local file="$1" target="$2" state="$3" finished="$4"
  STATUS_MODEL_FILE="$file" UU_STATUS_MODEL_FILE="$file" \
    bash -c 'source "$1"; sync_remote_last_update "$2" "$3" "$4" 0' \
    _ "$WORK_DIR/sync.sh" "$target" "$state" "$finished"
}

run_update_result() {
  local file="$1"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$file" \
    bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT ext01 success 0' \
    _ "$SOURCE_ROOT/status-model.sh"
}

wait_ready() {
  for _ in $(seq 1 200); do
    [[ -f "$WORK_DIR/ready" ]] && return 0
    sleep 0.01
  done
  echo 'timed out waiting for paused writer' >&2
  return 1
}

# External update result is written while remote sync is paused before its
# atomic replace.  The shared lock must make the external writer wait.
write_status "$WORK_DIR/status.json"
rm -f -- "$WORK_DIR/ready" "$WORK_DIR/release"
PYTHONPATH="$WORK_DIR" UU_TEST_PAUSE_DESTINATION="$WORK_DIR/status.json" \
  UU_TEST_READY="$WORK_DIR/ready" UU_TEST_RELEASE="$WORK_DIR/release" \
  STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; sync_remote_last_update 201 completed 2026-09-25T10:00:00Z 0' \
  _ "$WORK_DIR/sync.sh" &
sync_pid=$!
wait_ready
run_update_result "$WORK_DIR/status.json" &
update_pid=$!
sleep 0.1
touch "$WORK_DIR/release"
wait "$sync_pid"
wait "$update_pid"
assert_results "$WORK_DIR/status.json" ext01 201

# Reverse interleaving: pause the real STATUS_MODEL_UPDATE_RESULT writer,
# then run remote sync. Both updates must survive.
write_status "$WORK_DIR/status.json"
rm -f -- "$WORK_DIR/ready" "$WORK_DIR/release"
PYTHONPATH="$WORK_DIR" UU_TEST_PAUSE_DESTINATION="$WORK_DIR/status.json" \
  UU_TEST_READY="$WORK_DIR/ready" UU_TEST_RELEASE="$WORK_DIR/release" \
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_UPDATE_RESULT ext01 success 0' \
  _ "$SOURCE_ROOT/status-model.sh" &
update_pid=$!
wait_ready
run_sync "$WORK_DIR/status.json" 201 completed 2026-09-25T10:01:00Z &
sync_pid=$!
sleep 0.1
touch "$WORK_DIR/release"
wait "$update_pid"
wait "$sync_pid"
assert_results "$WORK_DIR/status.json" ext01 201

# Two remote-result writers must not overwrite one another.
write_status "$WORK_DIR/status.json"
rm -f -- "$WORK_DIR/ready" "$WORK_DIR/release"
PYTHONPATH="$WORK_DIR" UU_TEST_PAUSE_DESTINATION="$WORK_DIR/status.json" \
  UU_TEST_READY="$WORK_DIR/ready" UU_TEST_RELEASE="$WORK_DIR/release" \
  STATUS_MODEL_FILE="$WORK_DIR/status.json" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  bash -c 'source "$1"; sync_remote_last_update 201 completed 2026-09-25T10:02:00Z 0' \
  _ "$WORK_DIR/sync.sh" &
sync_pid=$!
wait_ready
run_sync "$WORK_DIR/status.json" 202 completed 2026-09-25T10:03:00Z &
second_sync_pid=$!
sleep 0.1
touch "$WORK_DIR/release"
wait "$sync_pid"
wait "$second_sync_pid"
assert_results "$WORK_DIR/status.json" 201 202

echo 'status writer concurrency regression: PASS'
