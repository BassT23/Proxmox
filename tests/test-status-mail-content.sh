#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T09:00:01Z","exit_code":0,"pending_before":0}},
  {"id":"guest:201","type":"lxc","node":"node1","name":"cluster-lxc","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T09:00:02Z","exit_code":0,"pending_before":2}},
  {"id":"external:ext01","type":"external","name":"external-one","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-18T09:00:03Z","exit_code":0,"pending_before":1}},
  {"id":"guest:202","type":"vm","node":"node1","name":"remote-vm","check_status":"ok","reachable":true,"updates":{"available":2},"last_update":{"status":"completed_with_warnings","timestamp":"2026-10-18T09:00:04Z","exit_code":0,"pending_before":2}},
  {"id":"guest:203","type":"lxc","node":"node1","name":"stopped-lxc","check_status":"not_checked","reachable":true,"updates":{"available":null},"skip_reason":{"code":"STOPPED_READ_ONLY","message":"Guest intentionally not checked"},"last_update":{"status":"skipped","timestamp":"2026-10-18T09:00:05Z","exit_code":10,"pending_before":null}},
  {"id":"guest:204","type":"vm","node":"node1","name":"unsupported-vm","check_status":"unsupported","reachable":true,"updates":{"available":null},"error":{"code":"UNSUPPORTED_GUEST_OS","message":"unsupported"},"last_update":{"status":"unsupported","timestamp":"2026-10-18T09:00:06Z","exit_code":21}},
  {"id":"guest:205","type":"lxc","node":"node1","name":"failed-lxc","check_status":"error","reachable":true,"updates":{"available":null},"last_update":{"status":"failed","timestamp":"2026-10-18T09:00:07Z","exit_code":17}},
  {"id":"external:stale","type":"external","name":"stale-external","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-10-17T09:00:00Z","exit_code":0,"pending_before":0}},
  {"id":"guest:206","type":"vm","node":"node1","name":"missing-result","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON

LOCAL_FILES="$WORK_DIR" bash -c \
  'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update "" "" 2026-10-18T09:00:00Z' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/mail.txt"

grep -Fxq 'STATE=issues' "$WORK_DIR/mail.txt"
[[ $(grep -Fc 'Guests:' "$WORK_DIR/mail.txt") -eq 1 ]]
grep -Fq '✅ node1' "$WORK_DIR/mail.txt"
grep -Fq '✅ 🐧 201 · cluster-lxc' "$WORK_DIR/mail.txt"
grep -Fq '   Successfully updated' "$WORK_DIR/mail.txt"
grep -Fq '✅ 🌐 ext01 · external-one' "$WORK_DIR/mail.txt"
grep -Fq '⚠️ ❔ 202 · remote-vm' "$WORK_DIR/mail.txt"
grep -Fq '   Update completed with warnings' "$WORK_DIR/mail.txt"
grep -Fq '💤 🐧 203 · stopped-lxc' "$WORK_DIR/mail.txt"
grep -Fq '   Skipped by configuration' "$WORK_DIR/mail.txt"
grep -Fq '💤 ❔ 204 · unsupported-vm' "$WORK_DIR/mail.txt"
grep -Fq '   Update unsupported' "$WORK_DIR/mail.txt"
grep -Fq '❌ 🐧 205 · failed-lxc' "$WORK_DIR/mail.txt"
grep -Fq '   Update failed' "$WORK_DIR/mail.txt"
grep -Fq '⚠️ 🌐 stale · stale-external' "$WORK_DIR/mail.txt"
grep -Fq '⚠️ ❔ 206 · missing-result' "$WORK_DIR/mail.txt"

for target in cluster-lxc external-one remote-vm stopped-lxc unsupported-vm failed-lxc stale-external missing-result; do
  [[ $(grep -Fc "$target" "$WORK_DIR/mail.txt") -eq 1 ]]
done

if grep -A1 -F 'stale-external' "$WORK_DIR/mail.txt" | grep -Fq 'Successfully updated'; then
  echo 'stale update result was rendered as current success' >&2
  exit 1
fi
if grep -A1 -F 'missing-result' "$WORK_DIR/mail.txt" | grep -Fq 'Successfully updated'; then
  echo 'missing update result was rendered as current success' >&2
  exit 1
fi
if grep -A1 -F 'remote-vm' "$WORK_DIR/mail.txt" | grep -Fq 'Successfully updated'; then
  echo 'completed_with_warnings was rendered as successful update' >&2
  exit 1
fi

# An invalid run boundary must fail closed instead of treating historical
# last_update records as current.
LOCAL_FILES="$WORK_DIR" bash -c \
  'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update "" "" invalid-timestamp' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json" > "$WORK_DIR/invalid-run.txt"
if grep -Fq 'Successfully updated' "$WORK_DIR/invalid-run.txt" ||
   grep -Fq 'Update completed with warnings' "$WORK_DIR/invalid-run.txt"; then
  echo 'invalid run boundary allowed a current update result' >&2
  exit 1
fi

echo 'status mail content tests: PASS'
