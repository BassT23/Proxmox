#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

LOCAL_FILES="$WORK_DIR/local"
REMOTE_FILES="$WORK_DIR/remote"
mkdir -p "$LOCAL_FILES/VMs" "$REMOTE_FILES"
printf 'IN_HEADLESS_MODE="true"\n' > "$LOCAL_FILES/update.conf"
cat > "$LOCAL_FILES/internal-ssh.conf" <<'EOF'
schema_version=1
[node:node2]
host=node2-gateway
user=root
port=22
[vm:301]
host=vm301.example
user=checker
port=2201
identity_file=/root/.ssh/vm301
[vm:302]
host=vm302.example
user=foreign
port=2202
identity_file=/root/.ssh/vm302
EOF
cat > "$LOCAL_FILES/VMs/301" <<'EOF'
IP="192.0.2.301"
USER="legacy-checker"
SSH_VM_PORT="2201"
EOF
cat > "$LOCAL_FILES/VMs/302" <<'EOF'
IP="192.0.2.302"
USER="foreign"
SSH_VM_PORT="2202"
EOF
chmod 600 "$LOCAL_FILES/internal-ssh.conf" "$LOCAL_FILES/VMs/301" "$LOCAL_FILES/VMs/302"

export LOCAL_FILES CONFIG_FILE="$LOCAL_FILES/update.conf"
export TAG_FILTER_FILE="$ROOT_DIR/tag-filter.sh"
export TARGET_RUNTIME_FILE="$ROOT_DIR/target-runtime.sh"
export CLUSTER_TARGET_FILE="$ROOT_DIR/cluster-target.sh"
export INTERNAL_SSH_FILE="$ROOT_DIR/internal-ssh.sh"
export STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
export STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records"
export STATUS_MODEL_GENERATION_FILE="$WORK_DIR/status.generations"
export STATUS_MODEL_NODE=controller
export UU_CLUSTER_RESOURCES_JSON='[{"type":"qemu","vmid":301,"node":"node2","name":"ssh-vm"},{"type":"qemu","vmid":302,"node":"node3","name":"foreign-vm"},{"type":"lxc","vmid":401,"node":"node2","name":"container"}]'

# Load the production helper and the real global remote staging function
# without entering check-updates.sh's command-line dispatcher.
sed '/^# Output to file/,$d' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-functions.sh"
# shellcheck disable=SC1090,SC1091
source "$WORK_DIR/check-functions.sh"

REMOTE_CALLS="$WORK_DIR/remote.calls"
FAIL_PROFILE=""
CHECK_REMOTE_SSH() {
  printf 'ssh %s\n' "$*" >> "$REMOTE_CALLS"
  return 0
}

CHECK_REMOTE_SCP() {
  local argc source destination path
  local -a args=("$@")
  argc=$#
  source="${args[$((argc - 2))]}"
  destination="${args[$((argc - 1))]}"
  if [[ -n "$FAIL_PROFILE" && "$source" == "$LOCAL_FILES/VMs/$FAIL_PROFILE" ]]; then
    return 1
  fi
  path="${destination#*:}"
  mkdir -p -- "$REMOTE_FILES$(dirname -- "$path")"
  cp -- "$source" "$REMOTE_FILES$path"
  printf 'scp %s -> %s\n' "$source" "$path" >> "$REMOTE_CALLS"
}

STATUS_MODEL_INIT
CHECK_HOST_STAGE_VM_SSH_CONTEXT node2 node2 22 /tmp/check-node
STATUS_MODEL_FINISH >/dev/null

[[ -f "$REMOTE_FILES/tmp/check-node/internal-ssh.sh" ]]
[[ -f "$REMOTE_FILES/tmp/check-node/internal-ssh.conf" ]]
[[ -f "$REMOTE_FILES/tmp/check-node/VMs/301" ]]
[[ ! -e "$REMOTE_FILES/tmp/check-node/VMs/302" ]]
grep -Fq '[vm:301]' "$REMOTE_FILES/tmp/check-node/internal-ssh.conf"
if grep -Fq '[vm:302]' "$REMOTE_FILES/tmp/check-node/internal-ssh.conf"; then exit 1; fi
if grep -Fq '[node:node2]' "$REMOTE_FILES/tmp/check-node/internal-ssh.conf"; then exit 1; fi
grep -Fq 'identity_file=/root/.ssh/vm301' "$REMOTE_FILES/tmp/check-node/internal-ssh.conf"
if grep -Fq 'vm302.example' "$REMOTE_FILES/tmp/check-node/internal-ssh.conf"; then exit 1; fi
grep -Fq "CHECK_HOST_STAGE_VM_SSH_CONTEXT \"\$HOST_NODE\" \"\$HOST\" \"\$SSH_PORT\" \"\$remote_check_dir\"" "$ROOT_DIR/check-updates.sh"
grep -Fq "LOCAL_FILES='\$remote_check_dir' CONFIG_FILE='\$remote_check_dir/update.conf'" "$ROOT_DIR/check-updates.sh"
grep -Fq "INTERNAL_SSH_FILE='\$remote_check_dir/internal-ssh.sh' INTERNAL_SSH_CONFIG_FILE='\$remote_check_dir/internal-ssh.conf'" "$ROOT_DIR/check-updates.sh"
grep -Fq 'INTERNAL_SSH_CONFIG_FILE=%q' "$ROOT_DIR/ultimate-updater"

python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
assert payload.get("targets", []) == []
PY

# A symlinked configuration is invalid even when its target would otherwise
# parse successfully; the remote run must fail closed instead of dropping the
# SSH-only VM from the global result.
mv -- "$LOCAL_FILES/internal-ssh.conf" "$LOCAL_FILES/internal-ssh.conf.real"
ln -s -- internal-ssh.conf.real "$LOCAL_FILES/internal-ssh.conf"
rm -f -- "$STATUS_MODEL_FILE" "$STATUS_MODEL_RECORD_FILE" "$STATUS_MODEL_GENERATION_FILE"
FAIL_PROFILE=""
STATUS_MODEL_INIT
if CHECK_HOST_STAGE_VM_SSH_CONTEXT node2 node2 22 /tmp/check-node-invalid; then
  echo 'expected invalid SSH configuration failure' >&2
  exit 1
fi
STATUS_MODEL_FINISH >/dev/null
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
targets = {str(item.get("id")): item for item in payload.get("targets", [])}
assert targets["301"]["error"]["code"] == "VM_SSH_STAGING_FAILED"
PY
rm -f -- "$LOCAL_FILES/internal-ssh.conf"
mv -- "$LOCAL_FILES/internal-ssh.conf.real" "$LOCAL_FILES/internal-ssh.conf"

# A failed profile transfer must be represented explicitly; it must not turn
# into an apparently complete remote check with the VM silently omitted.
rm -f -- "$STATUS_MODEL_FILE" "$STATUS_MODEL_RECORD_FILE" "$STATUS_MODEL_GENERATION_FILE"
FAIL_PROFILE=301
STATUS_MODEL_INIT
if CHECK_HOST_STAGE_VM_SSH_CONTEXT node2 node2 22 /tmp/check-node-failure; then
  echo 'expected VM SSH staging failure' >&2
  exit 1
fi
STATUS_MODEL_FINISH >/dev/null
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
targets = {str(item.get("id")): item for item in payload.get("targets", [])}
assert targets["301"]["check_status"] == "error"
assert targets["301"]["error"]["code"] == "VM_SSH_STAGING_FAILED"
assert "302" not in targets
PY

echo 'global remote VM SSH staging tests: PASS'
