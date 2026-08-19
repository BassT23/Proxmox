#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/local/temp"
cat > "$WORK_DIR/pct" <<'EOF'
#!/bin/bash
case "${1:-}" in
  list) printf 'VMID Status\n912 stopped\n' ;;
  config) exit 0 ;;
  status) cat "$PCT_STATE" ;;
  start) printf 'status: running\n' > "$PCT_STATE" ;;
  shutdown) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod 750 "$WORK_DIR/pct"
printf 'status: stopped\n' > "$WORK_DIR/pct-state"
export PCT_STATE="$WORK_DIR/pct-state"

awk '/^## Container ##$/{copy=1} /^# Container Check$/{exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-check.sh"

PATH="$WORK_DIR:$PATH" bash -c '
  set -euo pipefail
  LOCAL_FILES="$1/local"
  CONTAINER_CHECK_START() { :; }
  source "$1/container-check.sh"
  CONTAINERS=""
  STOPPED=true
  ONLY=""
  EXCLUDED=""
  RD=""
  CL=""
  CHECK_FAILURE=0
  guest_id_matches() { return 1; }
  WAIT_FOR_BOOTUP_LXC() { return 0; }
  CHECK_CONTAINER() { :; }
  cluster_target_guest_name() { printf "fixture-912\n"; }
  STATUS_MODEL_NODE="Proxmox-Test-1"
  STATUS_MODEL_GUEST_NAME=""
  STATUS_MODEL_RECORD() { printf "%s\n" "$*" > "$LOCAL_FILES/lifecycle-record"; }
  CONTAINER_CHECK_START
  [[ "$CHECK_FAILURE" -eq 1 ]]
  grep -Fq "LIFECYCLE_RESTORE_FAILED" "$LOCAL_FILES/lifecycle-record"
' _ "$WORK_DIR"

# shellcheck disable=SC2016 # assert the literal forbidden shell fragment.
if grep -Fq 'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "reboot"' "$ROOT_DIR/check-updates.sh"; then
  echo 'check path still reboots guests' >&2
  exit 1
fi
echo 'lxc lifecycle failure fixture: PASS'
