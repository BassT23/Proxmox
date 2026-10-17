#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the actual single-target lifecycle function with the API check
# context.  The pre-fix implementation ignored INITIAL_INVENTORY here and
# started a stopped LXC when CHECK_STOPPED_CONTAINER was enabled.
sed -n '/^# Container Check$/,/^## VM ##$/p' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

CALLS=""
PCT_STATE="status: stopped"

pct() {
  case "${1:-}" in
    status) printf '%s\n' "$PCT_STATE" ;;
    start) PCT_STATE="status: running"; CALLS+=$'pct start\n' ;;
    shutdown) PCT_STATE="status: stopped"; CALLS+=$'pct shutdown\n' ;;
    *) return 0 ;;
  esac
}

timeout() { shift; "$@"; }
RUN_PROXMOX_CAPTURE() { "$@"; }
WAIT_FOR_BOOTUP_LXC() { return 0; }
CHECK_CONTAINER() { CALLS+=$'checked\n'; return 0; }
CHECK_CONTAINER_FAILURE() { CALLS+="failure $*"$'\n'; return 1; }
STATUS_MODEL_RECORD() { CALLS+="record $*"$'\n'; }
cluster_target_guest_name() { printf 'fixture-lxc\n'; }

LOCAL_FILES=$(dirname -- "$1")
mkdir -p "$LOCAL_FILES/temp"
STOPPED=true
RUNNING=true
RDU=false
CHECK_FAILURE=0
STATUS_MODEL_NODE=test-node
YL=""
CL=""
RD=""
GN=""
BL=""
OS=debian
UU_EXPLICIT_TARGET_CHECK=true
INITIAL_INVENTORY=true
source "$1"
CHECK_CONTAINER() { CALLS+=$'checked\n'; return 0; }

for UU_EXPLICIT_TARGET_CHECK in false true; do
  CALLS=""
  PCT_STATE="status: stopped"
  CHECK_SINGLE_CONTAINER 930
  [[ "$PCT_STATE" == "status: stopped" ]]
  [[ "$CALLS" != *'pct start'* ]]
  [[ "$CALLS" != *'pct shutdown'* ]]
  [[ "$CALLS" != *$'\nchecked\n'* ]]
  [[ "$CALLS" == *'not_checked STOPPED_READ_ONLY'* ]]
  [[ "$CALLS" == *'initial inventory did not start it'* ]]
done

# A normal explicit single-target check keeps its established lifecycle
# semantics when the API-only initial-inventory context is absent.
CALLS=""
PCT_STATE="status: stopped"
INITIAL_INVENTORY=false
CHECK_SINGLE_CONTAINER 930
[[ "$PCT_STATE" == "status: stopped" ]]
[[ "$CALLS" == *'pct start'* ]]
[[ "$CALLS" == *'pct shutdown'* ]]
[[ "$CALLS" == *'checked'* ]]

# A running API target remains checkable and must not receive lifecycle calls.
CALLS=""
PCT_STATE="status: running"
INITIAL_INVENTORY=true
CHECK_CONTAINER() { CALLS+=$'checked-running\n'; return 0; }
CHECK_SINGLE_CONTAINER 930
[[ "$CALLS" == *'checked-running'* ]]
[[ "$CALLS" != *'pct start'* ]]
[[ "$CALLS" != *'pct shutdown'* ]]
HARNESS

chmod 750 "$WORK_DIR/harness.sh"
bash "$WORK_DIR/harness.sh" "$WORK_DIR/container-functions.sh"

echo 'API single-LXC lifecycle safety: PASS'
