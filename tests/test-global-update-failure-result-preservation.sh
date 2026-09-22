#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
cp "$ROOT_DIR/job-runner.sh" "$WORK_DIR/local/job-runner.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"
cp "$ROOT_DIR/ultimate-updater" "$WORK_DIR/local/ultimate-updater"
chmod 755 "$WORK_DIR/local/job-runner.sh" "$WORK_DIR/local/ultimate-updater"

cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:01Z","exit_code":0}},
  {"id":"101","type":"vm","node":"node1","name":"vm-101","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:02Z","exit_code":0}},
  {"id":"external-linux","type":"external","name":"external-linux","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:03Z","exit_code":0}}
]}
JSON
cat > "$WORK_DIR/remote-status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node2","type":"host","node":"node2","name":"node2","os":"Proxmox","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"last_update":{"status":"success","timestamp":"2026-09-22T10:00:05Z","exit_code":0}},
  {"id":"200","type":"vm","node":"node2","name":"vm-200","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:06Z","exit_code":0}},
  {"id":"201","type":"lxc","node":"node2","name":"ct-201","check_status":"error","reachable":true,"updates":{"available":null},"last_update":{"status":"failed","timestamp":"2026-09-22T10:00:07Z","exit_code":42}}
]}
JSON
cat > "$WORK_DIR/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
command=$(printf '%s\n' "$@" | tail -n 1)
if [[ "$command" == *".state"* ]]; then
  if [[ "${REMOTE_STATE_MODE:-completed}" == running ]]; then
    printf 'schema_version=1\nunit=ultimate-updater-update-node-node2-failure\ntarget=node-node2\nstate=running\nstarted_at=2026-09-22T10:00:00Z\nfinished_at=\nexit_code=\ntype=update\nsource=remote\ninteractive=false\n'
  else
    printf 'schema_version=1\nunit=ultimate-updater-update-node-node2-failure\ntarget=node-node2\nstate=completed\nstarted_at=2026-09-22T10:00:00Z\nfinished_at=2026-09-22T10:00:09Z\nexit_code=0\ntype=update\nsource=remote\ninteractive=false\n'
  fi
elif [[ "$command" == *"status.json" ]]; then
  cat "$REMOTE_STATUS"
elif [[ "$command" == *"post-update-status.rc" ]]; then
  printf '0\n'
elif [[ "$command" == *"rm -rf"* ]]; then
  :
else
  echo "unexpected fake ssh command: $command" >&2
  exit 1
fi
SSH
chmod 755 "$WORK_DIR/bin/ssh"
cat > "$WORK_DIR/update-fails.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod 755 "$WORK_DIR/update-fails.sh"

write_global_state() {
  local jobs="$1" unit="$2"
  mkdir -p "$jobs"
  cat > "$jobs/$unit.state" <<STATE
schema_version=1
unit=$unit
target=all-systems
state=running
started_at=2026-09-22T10:00:00Z
finished_at=
exit_code=
type=update
source=
interactive=false
STATE
}
run_failure() {
  local jobs="$1" unit="$2"
  set +e
  UU_JOB_STATE_DIR="$jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
    UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
    UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh" \
    UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater" \
    UU_REMOTE_JOB_STATE_DIR="$jobs/remote" PATH="$WORK_DIR/bin:$PATH" \
    "$WORK_DIR/local/job-runner.sh" run-global "$unit" "$WORK_DIR/update-fails.sh"
  local rc=$?
  set -e
  [[ "$rc" -eq 1 ]]
  grep -Fq 'state=failed' "$jobs/$unit.state"
  grep -Fq 'exit_code=1' "$jobs/$unit.state"
}

export UU_JOB_STATE_DIR="$WORK_DIR/jobs"
export UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json"
export UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh"
export UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater"
export REMOTE_STATUS="$WORK_DIR/remote-status.json"

write_global_state "$WORK_DIR/jobs" ultimate-updater-update-all-failure
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
  "$WORK_DIR/local/job-runner.sh" record-remote \
  ultimate-updater-update-node-node2-failure node-node2 node2 remote-node 22 \
  /tmp/ultimate-updater-update-node-9-8-7
run_failure "$WORK_DIR/jobs" ultimate-updater-update-all-failure

python3 - "$WORK_DIR/local/status.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {item["id"]: item for item in payload["targets"]}
assert {"host:node1", "101", "host:node2", "200", "201", "external-linux"} <= set(targets)
assert targets["host:node2"]["last_update"]["status"] == "success"
assert targets["200"]["last_update"]["status"] == "success"
assert targets["201"]["last_update"] == {"status": "failed", "timestamp": "2026-09-22T10:00:07Z", "exit_code": 42}
PY
notification=$(STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status.json")
grep -Fq node2 <<<"$notification"
grep -Fq vm-200 <<<"$notification"
grep -Fq ct-201 <<<"$notification"
if grep -Fq 'Result unavailable' <<<"$notification"; then exit 1; fi

# A running remote job must not be imported by the common collection step.
cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":0}}]}
JSON
mkdir -p "$WORK_DIR/jobs-running/remote"
UU_JOB_STATE_DIR="$WORK_DIR/jobs-running" UU_LOCAL_FILES="$WORK_DIR/local" \
  "$WORK_DIR/local/job-runner.sh" record-remote \
  ultimate-updater-update-node-node2-running node-node2 node2 remote-node 22 \
  /tmp/ultimate-updater-update-node-9-8-7
write_global_state "$WORK_DIR/jobs-running" ultimate-updater-update-all-running
REMOTE_STATE_MODE=running run_failure "$WORK_DIR/jobs-running" ultimate-updater-update-all-running
python3 - "$WORK_DIR/local/status.json" <<'PY'
import json
import sys
ids = {item["id"] for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
assert "host:node2" not in ids
assert "200" not in ids
assert "201" not in ids
PY

echo 'failed global update remote result preservation: PASS'
