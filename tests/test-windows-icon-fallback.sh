#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:986","type":"vm","node":"node1","name":"windows-os","os":"Windows Server 2022","check_status":"updates_available","reachable":true,"updates":{"available":1}},
  {"id":"guest:987","type":"vm","node":"node1","name":"windows-updater","updater":"windows-update","check_status":"error","reachable":true,"updates":{"available":null}},
  {"id":"guest:988","type":"vm","node":"node1","name":"windows-history","windows_update":{"source":"Windows Update Agent","history":[]},"check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:989","type":"vm","node":"node1","name":"unknown-vm","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:990","type":"vm","node":"node1","name":"linux-vm","os":"Debian 12","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:991","type":"lxc","node":"node1","name":"linux-lxc","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"external:ext01","type":"external","name":"external-one","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:992","type":"vm","node":"node1","name":"offline-windows","updater":"windows-update","check_status":"offline","reachable":false,"updates":{"available":null}},
  {"id":"guest:993","type":"vm","node":"node1","name":"stopped-unknown","check_status":"not_checked","reachable":false,"updates":{"available":null},"skip_reason":{"code":"STOPPED_READ_ONLY","message":"Guest intentionally not checked"}}
]}
JSON

LOCAL_FILES="$WORK_DIR" bash -c \
  'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2"' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/mail.txt"

grep -Fq '🪟 986 · windows-os' "$WORK_DIR/mail.txt"
grep -Fq '🪟 987 · windows-updater' "$WORK_DIR/mail.txt"
grep -Fq '🪟 988 · windows-history' "$WORK_DIR/mail.txt"
grep -Fq '❔ 989' "$WORK_DIR/mail.txt"
if grep -Fq '🐧 989' "$WORK_DIR/mail.txt"; then
  echo 'unknown VM was incorrectly rendered with the Linux icon' >&2
  exit 1
fi
grep -Fq '🐧 990 · linux-vm' "$WORK_DIR/mail.txt"
grep -Fq '✅ 🐧 991 · linux-lxc' "$WORK_DIR/mail.txt"
grep -Fq '✅ 🌐 ext01 · external-one' "$WORK_DIR/mail.txt"
grep -Fq '⚠️ 🪟 992 · offline-windows' "$WORK_DIR/mail.txt"
grep -Fq 'Not reachable:' "$WORK_DIR/mail.txt"
grep -Fq 'Skipped:' "$WORK_DIR/mail.txt"

# The WebUI must use the same existing Windows metadata fallback for its
# Windows-specific target details; this is not a new live lookup.
grep -Fq 't?.updater' "$ROOT_DIR/web-ui/server.py"
grep -Fq 't?.windows_update?.source' "$ROOT_DIR/web-ui/server.py"

echo 'Windows icon fallback tests: PASS'
