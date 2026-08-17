#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true' EXIT

awk '/^CONTAINER_CHECK_START \(\) \{/{copy=1} /^# Container Check$/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-functions.sh"
awk '/^VM_CHECK_START \(\) \{/{copy=1} /^# VM Check$/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/vm-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOG_FILE=${LOG_FILE:?}
LOCAL_FILES="$PWD"
INITIAL_INVENTORY=true
STOPPED=true
RUNNING=true
STOPPED_VM=true
PAUSED_VM=true
RUNNING_VM=true
ONLY=""
EXCLUDED=""
VM_START_DELAY=0
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=""
BL="" OR="" RD="" GN="" CL=""

record() { printf 'record:%s\n' "$*" >> "$LOG_FILE"; }
STATUS_MODEL_RECORD() { record "status $*"; }
guest_id_matches() { return 1; }
SANITIZE_NUMBER() { printf '%s' "$1"; }
WAIT_FOR_BOOTUP_LXC() { return 0; }
WAIT_FOR_QGA() { return 0; }
CHECK_CONTAINER() { record "check-container $*"; }
CHECK_VM() { record "check-vm $*"; }
timeout() { shift; "$@"; }

pct() {
  printf 'pct %s\n' "$*" >> "$LOG_FILE"
  case "$1" in
    list) printf 'VMID Status\n105 stopped\n' ;;
    config) printf 'ostype: debian\n' ;;
    status) printf 'status: stopped\n' ;;
  esac
}

qm() {
  printf 'qm %s\n' "$*" >> "$LOG_FILE"
  case "$1" in
    list) printf 'VMID NAME STATUS\n320 ai-ollama stopped\n321 paused-vm paused\n' ;;
    config) printf 'agent: 1\nostype: l26\nname: fixture\n' ;;
    status)
      [[ "$2" == 321 ]] && printf 'status: paused\n' || printf 'status: stopped\n'
      ;;
  esac
}

source "$WORK_DIR/container-functions.sh"
source "$WORK_DIR/vm-functions.sh"
CONTAINER_CHECK_START
VM_CHECK_START

grep -Fq 'status 105 lxc pct false' "$LOG_FILE"
grep -Fq 'status 320 vm qga false' "$LOG_FILE"
grep -Fq 'status 321 vm qga false' "$LOG_FILE"
if grep -Eq 'pct (start|shutdown|stop)|qm (start|shutdown|stop|resume|suspend)' "$LOG_FILE"; then
  echo 'initial inventory attempted a guest state transition' >&2
  exit 1
fi
HARNESS

chmod 750 "$WORK_DIR/harness.sh"
(cd "$WORK_DIR"; LOG_FILE="$WORK_DIR/commands.log"; export LOG_FILE WORK_DIR; bash "$WORK_DIR/harness.sh")

grep -Fq 'INITIAL_INVENTORY=true' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STOPPED_READ_ONLY' "$ROOT_DIR/check-updates.sh"
grep -Fq 'PAUSED_READ_ONLY' "$ROOT_DIR/check-updates.sh"
grep -Fq 'initial inventory did not start' "$ROOT_DIR/check-updates.sh"
grep -Fq 'initial inventory did not resume' "$ROOT_DIR/check-updates.sh"

echo 'initial inventory true read-only lifecycle tests: PASS'
