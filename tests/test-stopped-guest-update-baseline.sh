#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE\(\) \{/{copy=1} /^# All update result writes go through/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/baseline-functions.sh"
awk '/^CONTAINER_UPDATE_START \(\) \{/{copy=1} /^# Container Update$/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/container-start.sh"
awk '/^VM_UPDATE_START \(\) \{/{copy=1} /^# Detect the Proxmox guest OS/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/vm-start.sh"

cat > "$WORK_DIR/check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
kind=$1
target=$2
printf '%s %s\n' "$kind" "$target" >> "$CHECK_LOG"
if [[ "${CHECK_RC:-0}" -ne 0 ]]; then
  exit "$CHECK_RC"
fi
target_type=lxc
[[ "$kind" == cvm ]] && target_type=vm
checked_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
check_status=ok
[[ "${BASELINE:-0}" -gt 0 ]] && check_status=updates_available
cat > "$STATUS_MODEL_FILE" <<JSON
{"schema_version":1,"generated_at":"$checked_at","targets":[{"id":"$target","type":"$target_type","node":"$STATUS_MODEL_NODE","reachable":true,"check_status":"$check_status","updates":{"available":${BASELINE:-0}},"last_check":"$checked_at","package_checked_at":"$checked_at","package_data_invalidated":false,"package_mutation_in_progress":false}]}
JSON
CHECK
chmod 750 "$WORK_DIR/check.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
KIND=$3
BASELINE=$4
CHECK_RC=$5
SOURCE_DIR=$(dirname -- "$WORK_DIR")
LOCAL_FILES="$WORK_DIR/local"
TEMP_STATE_DIR="$WORK_DIR/temp"
CONFIG_FILE="$WORK_DIR/update.conf"
CHECK_SCRIPT="$SOURCE_DIR/check.sh"
STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh"
STATUS_MODEL_NODE=node1
STATUS_MODEL_FILE="$WORK_DIR/status.json"
CHECK_LOG="$WORK_DIR/check.log"
EVENTS="$WORK_DIR/events"
export BASELINE CHECK_RC CHECK_LOG
UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_RESULT_RECORDED=false
UU_UPDATE_PENDING_BEFORE_TARGET=106
UU_UPDATE_PENDING_BEFORE=0
SINGLE_UPDATE=true
ONLY=106
EXCLUDED=""
STOPPED_CONTAINER=true
RUNNING_CONTAINER=true
STOPPED_VM=true
RUNNING_VM=true
USE_INTERNAL_TARGET_SELECTION=false
WILL_STOP=false
START_WAITING=false
CCONTAINER=""
CVM=""
BL='' OR='' RD='' GN='' CL=''
mkdir -p "$LOCAL_FILES" "$TEMP_STATE_DIR"
: > "$CHECK_LOG"
: > "$EVENTS"
declare -A UPDATE_PENDING_BEFORE=()

source "$STATUS_MODEL_SCRIPT"
source "$SOURCE_DIR/baseline-functions.sh"

REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { printf 'invalidate %s\n' "$*" >> "$EVENTS"; return 0; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { printf 'complete %s\n' "$*" >> "$EVENTS"; return 0; }
UPDATE_TARGET_CAPABILITY_GUARD() { return 0; }
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH() { return 0; }
ERROR() { UPDATE_FAILURE=true; printf 'error %s\n' "$ERROR_MSG" >> "$EVENTS"; return 0; }
RECORD_UPDATE_RESULT() { printf 'result %s\n' "$*" >> "$EVENTS"; return 0; }
guest_id_matches() { return 1; }
WAIT_FOR_BOOTUP_LXC() { printf 'wait-lxc\n' >> "$EVENTS"; return 0; }
CAPTURE_POST_UPDATE_STATUS() { printf 'capture %s\n' "$*" >> "$EVENTS"; return 0; }
RUN_PROXMOX_COMMAND() {
  printf 'prox %s\n' "$*" >> "$EVENTS"
  case "$1" in
    pct)
      [[ "$2" == start ]] && LXC_STATE='status: running'
      [[ "$2" == shutdown ]] && LXC_STATE='status: stopped'
      ;;
    qm)
      [[ "$2" == start ]] && VM_STATE='status: running'
      [[ "$2" == shutdown ]] && VM_STATE='status: stopped'
      ;;
  esac
  return 0
}
timeout() { shift; "$@"; }

pct() {
  case "$1" in
    list) printf 'VMID Status\n106 stopped\n' ;;
    config) printf 'ostype: debian\n' ;;
    status) printf '%s\n' "$LXC_STATE" ;;
  esac
}
qm() {
  case "$1" in
    list) printf 'VMID NAME STATUS\n106 fixture stopped\n' ;;
    config) printf 'ostype: l26\nname: fixture\n' ;;
    status) printf '%s\n' "$VM_STATE" ;;
  esac
}

if [[ "$KIND" == lxc ]]; then
  LXC_STATE='status: stopped'
  UPDATE_CONTAINER() {
    printf 'mutation lxc baseline=%s\n' "${UPDATE_PENDING_BEFORE[106]-}" >> "$EVENTS"
    [[ "${UPDATE_PENDING_BEFORE[106]-}" == "$BASELINE" ]]
    [[ "${UU_UPDATE_PENDING_BEFORE_TARGET:-}" == 106 ]]
    [[ "${UU_UPDATE_PENDING_BEFORE:-}" == "$BASELINE" ]]
  }
  source "$SOURCE_DIR/container-start.sh"
  CONTAINERS=106
  CONTAINER_UPDATE_START
else
  VM_STATE='status: stopped'
  QGA_CONFIG_ENABLED() { return 0; }
  INTERNAL_SSH_TARGET_STATE() { return 1; }
  UPDATE_VM() {
    printf 'mutation vm baseline=%s\n' "${UPDATE_PENDING_BEFORE[106]-}" >> "$EVENTS"
    [[ "${UPDATE_PENDING_BEFORE[106]-}" == "$BASELINE" ]]
    [[ "${UU_UPDATE_PENDING_BEFORE_TARGET:-}" == 106 ]]
    [[ "${UU_UPDATE_PENDING_BEFORE:-}" == "$BASELINE" ]]
  }
  source "$SOURCE_DIR/vm-start.sh"
  VMS=106
  VM_UPDATE_START
fi

if [[ "$CHECK_RC" -eq 0 ]]; then
  expected_command=ccontainer
  [[ "$KIND" == vm ]] && expected_command=cvm
  grep -Fxq "$expected_command 106" "$CHECK_LOG"
  grep -Fq "mutation $KIND baseline=$BASELINE" "$EVENTS"
else
  if grep -Fq 'mutation ' "$EVENTS"; then
    echo 'failed fresh baseline still reached package mutation' >&2
    exit 1
  fi
  grep -Fq 'PENDING_BEFORE_UNAVAILABLE' "$EVENTS"
fi
grep -Eq '^prox (pct|qm) shutdown 106$' "$EVENTS"
[[ "$KIND" == lxc && "$LXC_STATE" == 'status: stopped' ]] ||
  [[ "$KIND" == vm && "$VM_STATE" == 'status: stopped' ]]
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

for kind in lxc vm; do
  "$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR/$kind-zero" "$kind" 0 0
done
"$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR/lxc-positive" lxc 3 0
"$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR/lxc-failed" lxc 0 1
"$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR/vm-failed" vm 0 1

echo 'stopped guest update baseline lifecycle tests: PASS'
