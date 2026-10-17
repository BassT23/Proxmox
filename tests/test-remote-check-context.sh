#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

sed -n '/^remote_target_check() /,/^remote_target_update() /{ /^remote_target_update() /!p; }' \
  "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/remote-check.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
LOCAL_FILES="$ROOT_DIR"
SCRIPT_DIR="$ROOT_DIR"
CHECK_SCRIPT="$ROOT_DIR/check-updates.sh"
STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh"
CLUSTER_TARGET_SCRIPT="$ROOT_DIR/cluster-target.sh"
STATUS_MODEL_FILE="$WORK_DIR/status.json"
STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records"
REMOTE_NODE_ARGS=()
UU_JOB_SOURCE=initial-inventory
UU_NONINTERACTIVE=true
UU_SCHEDULED_CHECK=false
REMOTE_COMMAND_CAPTURE=""

resolve_remote_node_transport() {
  REMOTE_NODE_HOST=remote-test-node
  REMOTE_NODE_PORT=22
  REMOTE_NODE_USER=root
  REMOTE_NODE_ARGS=()
  return 0
}

scp() { return 0; }
ssh() {
  local command="${!#}"
  if [[ "$command" == mkdir\ -p* || "$command" == rm\ -rf* ]]; then
    return 0
  fi
  REMOTE_COMMAND_CAPTURE="$command"
  printf '{"schema_version":1,"targets":[{"id":"930","type":"lxc","transport":"ssh","reachable":true,"check_status":"ok"}]}\n'
}
timeout() { shift; "$@"; }
STATUS_MODEL_INIT() { : > "$STATUS_MODEL_RECORD_FILE"; }
STATUS_MODEL_IMPORT_FILE() { return 0; }
single_check_result() { return 0; }
finish_partial_status() { return 0; }

source "$WORK_DIR/remote-check.sh"
remote_target_check 930 container node2 ignored-host

[[ "$REMOTE_COMMAND_CAPTURE" == *'UU_JOB_SOURCE=initial-inventory'* ]]
[[ "$REMOTE_COMMAND_CAPTURE" == *'UU_NONINTERACTIVE=true'* ]]
[[ "$REMOTE_COMMAND_CAPTURE" == *'UU_SCHEDULED_CHECK=false'* ]]
HARNESS

chmod 750 "$WORK_DIR/harness.sh"
bash "$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR"

echo 'remote API check context propagation: PASS'
