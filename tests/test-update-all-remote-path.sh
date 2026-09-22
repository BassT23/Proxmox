#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034 # Production function is sourced dynamically for this transport fixture.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
cp "$ROOT_DIR/job-runner.sh" "$WORK_DIR/local/job-runner.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"
cp "$ROOT_DIR/ultimate-updater" "$WORK_DIR/local/ultimate-updater"
chmod 755 "$WORK_DIR/local/job-runner.sh" "$WORK_DIR/local/ultimate-updater"
for helper in check-updates.sh apt-count.py rpm-count.py package-count.sh; do
  cp "$ROOT_DIR/$helper" "$WORK_DIR/local/$helper"
done
touch "$WORK_DIR/local/update-extras.sh" "$WORK_DIR/local/update.conf"

cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"101","type":"vm","node":"node1","name":"vm-101","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"external-linux","type":"external","name":"external-linux","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON
cp "$WORK_DIR/local/status.json" "$WORK_DIR/update-snapshot.json"
python3 - "$WORK_DIR/update-snapshot.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
for item in payload["targets"]:
    item["last_update"] = {"status": "success", "timestamp": "2026-09-22T10:00:01Z", "exit_code": 0}
json.dump(payload, open(path, "w", encoding="utf-8"))
PY

cat > "$WORK_DIR/remote-status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node2","type":"host","node":"node2","name":"node2","os":"Proxmox","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"last_update":{"status":"success","timestamp":"2026-09-22T10:00:05Z","exit_code":0}},
  {"id":"200","type":"vm","node":"node2","name":"vm-200","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:06Z","exit_code":0}},
  {"id":"201","type":"lxc","node":"node2","name":"ct-201","check_status":"error","reachable":true,"updates":{"available":null},"last_update":{"status":"failed","timestamp":"2026-09-22T10:00:07Z","exit_code":42}},
  {"id":"999","type":"vm","node":"node3","name":"foreign","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:08Z","exit_code":0}}
]}
JSON

cat > "$WORK_DIR/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
command=$(printf '%s\n' "$@" | tail -n 1)
ref=$(find "$UU_JOB_STATE_DIR/remote" -name '*.ref' -print -quit)
unit=$(awk -F= '$1 == "unit" {print $2; exit}' "$ref")
case "$command" in
  *".state"*)
    printf 'schema_version=1\nunit=%s\ntarget=node-node2\nstate=completed\nstarted_at=2026-09-22T10:00:00Z\nfinished_at=2026-09-22T10:00:09Z\nexit_code=0\ntype=update\nsource=remote\ninteractive=false\n' "$unit"
    ;;
  *"status.json"*) cat "$REMOTE_STATUS" ;;
  *"post-update-status.rc"*) printf '0\n' ;;
  *"rm -rf"*) : ;;
  *) echo "unexpected fake ssh command: $command" >&2; exit 1 ;;
esac
SSH
chmod 755 "$WORK_DIR/bin/ssh"

: > "$WORK_DIR/scp.log"
scp() {
  local source
  source=$(printf '%s\n' "$@" | tail -n 2 | head -n 1)
  printf '%s\n' "$(basename -- "$source")" >> "$WORK_DIR/scp.log"
}
ssh() {
  local command
  command=$(printf '%s\n' "$@" | tail -n 1)
  [[ "$command" == *"bash -s"* ]] && cat >/dev/null
  return 0
}

export PATH="$WORK_DIR/bin:$PATH"
export UU_JOB_STATE_DIR="$WORK_DIR/jobs"
export UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json"
export UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh"
export UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater"
export REMOTE_STATUS="$WORK_DIR/remote-status.json"

awk '/^UPDATE_HOST \(\) \{/{capture=1} capture{print} capture && /^# shellcheck disable=SC2015/{exit}' \
  "$ROOT_DIR/update.sh" | sed '$d' > "$WORK_DIR/update-host-function.sh"
LOCAL_FILES="$WORK_DIR/local"
SCRIPT_DIR="$ROOT_DIR"
SSH_PORT=22
WELCOME_SCREEN=false
HOST_NODE=node2
UPDATE_FAILURE=false
USE_INTERNAL_TARGET_SELECTION=false
EFFECTIVE_HEADLESS() { return 0; }
source "$WORK_DIR/update-host-function.sh"
UPDATE_HOST 10.0.0.2

grep -Fxq apt-count.py "$WORK_DIR/scp.log"
grep -Fxq rpm-count.py "$WORK_DIR/scp.log"
grep -Fxq package-count.sh "$WORK_DIR/scp.log"
grep -Fxq check-updates.sh "$WORK_DIR/scp.log"
grep -Fxq status-model.sh "$WORK_DIR/scp.log"
ref=$(find "$WORK_DIR/jobs/remote" -name '*.ref' -print -quit)
[[ -n "$ref" ]]

UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh" \
  UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater" \
  "$WORK_DIR/local/job-runner.sh" list >/dev/null

python3 - "$WORK_DIR/local/status.json" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
for item in payload["targets"]:
    if item["id"] in {"host:node1", "101", "external-linux"}:
        item.pop("last_update", None)
json.dump(payload, open(path, "w", encoding="utf-8"))
PY

source "$WORK_DIR/local/status-model.sh"
STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  STATUS_MODEL_PRESERVE_UPDATE_RESULTS "$WORK_DIR/update-snapshot.json" "2026-09-22T10:00:00Z"

python3 - "$WORK_DIR/local/status.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {item["id"]: item for item in payload["targets"]}
assert set(targets) == {"host:node1", "101", "host:node2", "200", "201", "external-linux"}
assert targets["host:node2"]["last_update"]["status"] == "success"
assert targets["200"]["last_update"]["status"] == "success"
assert targets["201"]["last_update"] == {"status": "failed", "timestamp": "2026-09-22T10:00:07Z", "exit_code": 42}
assert targets["external-linux"]["last_update"]["status"] == "success"
PY

echo 'real update-all remote path regression: PASS'
