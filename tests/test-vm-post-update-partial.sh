#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/local/bin"
cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","check_status":"ok","reachable":true,"updates":{"available":1},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:00Z","exit_code":0}},
  {"id":"100","type":"vm","check_status":"error","reachable":true,"updates":{"available":9},"last_update":{"status":"failed","timestamp":"2026-09-22T10:01:00Z","exit_code":1}},
  {"id":"310","type":"vm","check_status":"ok","reachable":true,"updates":{"available":2},"last_update":{"status":"success","timestamp":"2026-09-22T10:02:00Z","exit_code":0}},
  {"id":"191","type":"lxc","check_status":"ok","reachable":true,"updates":{"available":3},"last_update":{"status":"success","timestamp":"2026-09-22T10:03:00Z","exit_code":0}},
  {"id":"external-linux","type":"external","check_status":"ok","reachable":true,"updates":{"available":4},"last_update":{"status":"success","timestamp":"2026-09-22T10:04:00Z","exit_code":0}}
]}
JSON

cat > "$WORK_DIR/local/check-updates.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${STATUS_MODEL_PARTIAL:-}" == true ]] || {
  echo 'STATUS_MODEL_PARTIAL was not propagated to the remote process' >&2
  exit 42
}
source "$STATUS_MODEL_SCRIPT"
STATUS_MODEL_INIT
STATUS_MODEL_RECORD 100 vm qga true Debian apt 0 false ok "" "" node1 vm-100
STATUS_MODEL_FINISH
printf 'VM 100 refreshed\n'
CHECK
chmod 755 "$WORK_DIR/local/check-updates.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"

cat > "$WORK_DIR/local/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
remote_command="${@: -1}"
printf '%s\n' "$remote_command" > "$SSH_COMMAND_LOG"
bash -c "$remote_command"
SSH
chmod 755 "$WORK_DIR/local/bin/ssh"

awk '/^UPDATE_CHECK \(\) \{/,/^# Wait for bootup \/ reboot/{if ($0 !~ /^# Wait for bootup \/ reboot/) print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-check.sh"

export PATH="$WORK_DIR/local/bin:$PATH"
export LOCAL_FILES="$WORK_DIR/local"
export STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh"
export STATUS_MODEL_FILE="$WORK_DIR/local/status.json"
export STATUS_MODEL_RECORD_FILE="$WORK_DIR/local/status.records"
export SSH_COMMAND_LOG="$WORK_DIR/ssh-command"
export WELCOME_SCREEN=true CHOST=false CCONTAINER=false CVM=true VM=100
export HOSTNAME=test-node SSH_PORT=22 WILL_STOP=false
: > "$WORK_DIR/local/check-output"

# shellcheck disable=SC1091
source "$WORK_DIR/update-check.sh"
# shellcheck disable=SC1090
source "$STATUS_MODEL_SCRIPT"
UPDATE_CHECK

# The fake remote check above fails unless the command carries the partial
# merge environment into the remote process; this is the functional assertion.

python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys

targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert set(targets) == {"host:node1", "100", "310", "191", "external-linux"}
assert targets["100"]["check_status"] == "ok"
assert targets["100"]["updates"]["available"] == 0
assert targets["100"]["last_update"]["status"] == "success"
assert targets["310"]["last_update"]["status"] == "success"
assert targets["191"]["last_update"]["status"] == "success"
assert targets["external-linux"]["last_update"]["status"] == "success"
PY

echo 'VM post-update partial status regression: PASS'
