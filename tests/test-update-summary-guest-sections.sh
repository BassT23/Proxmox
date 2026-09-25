#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"110","type":"vm","node":"node1","name":"vm01","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":2}},
  {"id":"101","type":"lxc","node":"node1","name":"ct01","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":0}},
  {"id":"102","type":"lxc","node":"node1","name":"ct02","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","pending_before":0}}
]}
JSON

LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/rendered.txt"

[[ $(grep -Fc 'Guests:' "$WORK_DIR/rendered.txt") -eq 1 ]]
grep -Fq '🐧 110 · vm01' "$WORK_DIR/rendered.txt"
grep -Fq '🐧 101 · ct01' "$WORK_DIR/rendered.txt"
grep -Fq '🐧 102 · ct02' "$WORK_DIR/rendered.txt"
grep -Fq 'Successfully updated' "$WORK_DIR/rendered.txt"
[[ $(grep -Fc 'Up to date' "$WORK_DIR/rendered.txt") -eq 2 ]]

echo 'single generic Guests summary regression: PASS'
