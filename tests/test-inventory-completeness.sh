#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_ROOT=${UU_INVENTORY_SOURCE_ROOT:-$ROOT_DIR}
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the production inventory dispatch with local Proxmox shims.  The
# fixture deliberately includes consecutive stopped guests and VMs without a
# guest transport; no qm/pct lifecycle or guest command can reach a host.
awk '/^CONTAINER_CHECK_START \(\) \{/{copy=1} /^# Container Check$/{if(copy) exit} copy' \
  "$SOURCE_ROOT/check-updates.sh" > "$WORK_DIR/container-start.sh"
awk '/^VM_CHECK_START \(\) \{/{copy=1} /^CHECK_VM_LIFECYCLE \(\) \{/{if(copy) exit} copy' \
  "$SOURCE_ROOT/check-updates.sh" > "$WORK_DIR/vm-start.sh"

cat > "$WORK_DIR/inventory-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

LOCAL_FILES="$PWD"
LOG_FILE="$PWD/inventory.log"
INITIAL_INVENTORY=true
STOPPED=true
RUNNING=true
STOPPED_VM=true
PAUSED_VM=true
RUNNING_VM=true
RDU=false
ONLY=""
EXCLUDED=""
USE_INTERNAL_TARGET_SELECTION=false
VM_START_DELAY=0
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=stale-name-from-previous-target
BL='' OR='' RD='' GN='' CL=''

record() { printf '%s\n' "$*" >> "$LOG_FILE"; }
STATUS_MODEL_RECORD() { record "status:$*"; }
CHECK_CONTAINER() { record "lxc-check:$1 name=$STATUS_MODEL_GUEST_NAME"; }
CHECK_VM_LIFECYCLE() { record "vm-check:$1 name=$STATUS_MODEL_GUEST_NAME"; }
SANITIZE_NUMBER() { printf '%s' "$1"; }
guest_id_matches() { [[ "${1:-}" == "${2:-}" ]]; }
TARGET_SELECTION_ALLOWS() { return 0; }
QGA_CONFIG_ENABLED() { [[ "$1" == 128 ]]; }
INTERNAL_SSH_TARGET_STATE() { [[ "$1:$2" == vm:129 ]]; }
RUN_PROXMOX_COMMAND() { record "MUTATION:$*"; return 1; }
timeout() { shift; "$@"; }

cluster_target_guest_name() {
  case "$1" in
    105) printf 'zabbix\n' ;;
    106) printf 'CodeprojectAI\n' ;;
    108) printf 'another-stopped-lxc\n' ;;
    128) printf 'qga-vm\n' ;;
    129) printf 'ssh-vm\n' ;;
    130) printf '\n' ;;
    125) printf 'stopped-no-transport\n' ;;
    126) printf 'paused-no-transport\n' ;;
    127) printf 'running-no-transport\n' ;;
  esac
}

pct() {
  record "pct:$*"
  case "$1" in
    list) printf 'VMID Status\n105 running\n106 stopped\n107 stopped\n108 stopped\n' ;;
    config) printf 'ostype: debian\n' ;;
    status)
      case "$2" in
        105) printf 'status: running\n' ;;
        106|107|108) printf 'status: stopped\n' ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

qm() {
  record "qm:$*"
  case "$1" in
    list)
      printf 'VMID NAME STATUS\n125 stopped-no-transport stopped\n126 paused-no-transport paused\n127 running-no-transport running\n128 qga-vm running\n129 ssh-vm running\n130 unnamed stopped\n131 excluded stopped\n'
      ;;
    status)
      case "$2" in
        125|130|131) printf 'status: stopped\n' ;;
        126) printf 'status: paused\n' ;;
        127|128|129) printf 'status: running\n' ;;
        *) return 1 ;;
      esac
      ;;
    config) printf 'ostype: l26\n' ;;
    *) return 1 ;;
  esac
}

source "$1/container-start.sh"
source "$1/vm-start.sh"

CONTAINER_CHECK_START
grep -Fq 'lxc-check:105 name=zabbix' "$LOG_FILE"
grep -Fq 'status:106 lxc pct false' "$LOG_FILE"
grep -Fq 'CodeprojectAI' "$LOG_FILE"
grep -Fq 'status:107 lxc pct false' "$LOG_FILE"
grep -Fq 'status:108 lxc pct false' "$LOG_FILE"
grep -Fq 'test-node 107' "$LOG_FILE"

if grep -Eq 'MUTATION:.*pct (start|shutdown)' "$LOG_FILE"; then
  echo 'LXC inventory attempted a lifecycle mutation' >&2
  exit 1
fi

RUNNING=false
CONTAINER_CHECK_START
grep -Fq 'status:105 lxc pct false' "$LOG_FILE"
grep -Fq 'RUNNING_DISABLED' "$LOG_FILE"

# VMs without QGA/SSH must receive records, while configured QGA/SSH targets
# continue down their existing lifecycle dispatch path.
EXCLUDED=131
VM_CHECK_START
grep -Fq 'status:125 vm none false' "$LOG_FILE"
grep -Fq 'STOPPED_READ_ONLY' "$LOG_FILE"
grep -Fq 'status:126 vm none false' "$LOG_FILE"
grep -Fq 'PAUSED_READ_ONLY' "$LOG_FILE"
grep -Fq 'status:127 vm none false' "$LOG_FILE"
grep -Fq 'NO_SUPPORTED_TRANSPORT' "$LOG_FILE"
grep -Fq 'vm-check:128 name=qga-vm' "$LOG_FILE"
grep -Fq 'vm-check:129 name=ssh-vm' "$LOG_FILE"
grep -Fq 'status:130 vm none false' "$LOG_FILE"
grep -Fq 'VM 130' "$LOG_FILE"
if grep -Fq 'status:131 ' "$LOG_FILE"; then
  echo 'excluded VM was added to inventory' >&2
  exit 1
fi
if grep -Eq 'MUTATION:.*qm (start|resume|stop|suspend)' "$LOG_FILE"; then
  echo 'VM inventory attempted a lifecycle mutation' >&2
  exit 1
fi

RUNNING_VM=false
VM_CHECK_START
grep -Fq 'status:127 vm none false' "$LOG_FILE"
grep -Fq 'RUNNING_DISABLED' "$LOG_FILE"

printf '%s\n' 'inventory dispatch fixtures: PASS'
HARNESS
chmod 750 "$WORK_DIR/inventory-harness.sh"
(cd "$WORK_DIR" && bash inventory-harness.sh "$WORK_DIR")

# The neutral transport record must be interpreted as a skip and must not
# erase package provenance or an existing invalidation marker.
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "generated_at": None, "targets": [{
    "id": "127", "type": "vm", "node": "test-node", "name": "running-no-transport",
    "check_status": "ok", "error": None, "skip_reason": None,
    "updates": {"available": 4}, "normal_updates": 3, "security_updates": 1,
    "package_checked_at": "2026-10-18T09:00:00Z",
    "package_data_invalidated": True, "package_mutation_generation": 4,
    "package_mutation_in_progress": False,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/neutral.records" STATUS_MODEL_PARTIAL=true \
  bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 127 vm none false "" "" null null not_checked NO_SUPPORTED_TRANSPORT "No supported read-only transport" test-node running-no-transport
    STATUS_MODEL_FINISH
  ' _ "$SOURCE_ROOT/status-model.sh"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["check_status"] == "not_checked"
assert target["error"] is None
assert target["skip_reason"]["code"] == "NO_SUPPORTED_TRANSPORT"
assert target["package_checked_at"] == "2026-10-18T09:00:00Z"
assert target["package_data_invalidated"] is True
assert target["updates"]["available"] == 4
PY

grep -Fq 'NO_SUPPORTED_TRANSPORT' "$ROOT_DIR/status-model.sh"
grep -Fq 'NO_SUPPORTED_TRANSPORT' "$ROOT_DIR/docs/api-v1.md"
printf '%s\n' 'inventory completeness and target-name regression tests: PASS'
