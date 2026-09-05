#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Run the real CHECK_CONTAINER function with a remote-wrapper-shaped LOCAL_FILES
# directory. The wrapper creates its root directory, but not temp/.
awk '/^CHECK_CONTAINER_FAILURE\(\)/{copy=1} /^## VM ##/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-container.sh"
cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD/remote-run"
mkdir -p "$LOCAL_FILES"
CONTAINER=200
RDU=false
STATUS_MODEL_NODE=node2
STATUS_MODEL_GUEST_NAME=smarthome-service
INITIAL_INVENTORY=false
STATUS_MODEL_RECORD_FILE="$PWD/records"
SANITIZE_NUMBER() { tr -cd '0-9' <<< "$1"; }
READ_APT_UPDATE_COUNTS() { SECURITY_APT_UPDATES=0; NORMAL_APT_UPDATES=0; }
cluster_target_guest_name() { printf 'smarthome-service\n'; }
STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$STATUS_MODEL_RECORD_FILE"; }
RUN_PCT_COMMAND() {
  local id="$1"; shift
  [[ "$id" == 200 ]]
  [[ "${1:-}" == hostname ]] && printf 'smarthome-service\n'
  if [[ "${1:-}" == sh && "${2:-}" == -c && "${3:-}" == "cat /etc/os-release" ]]; then
    printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n'
  fi
  return 0
}
pct() {
  [[ "$1" == config && "$2" == 200 ]]
  printf 'ostype: unsupported\n'
}
source "$PWD/check-container.sh"
CHECK_CONTAINER 200
test -f "$LOCAL_FILES/temp/temp"
grep -Fq '200 lxc pct true Debian GNU/Linux 12 (bookworm)' "$STATUS_MODEL_RECORD_FILE"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"
(cd "$WORK_DIR" && bash harness.sh)

# Match the shell parameter syntax literally in the source assertion.
# shellcheck disable=SC2016
grep -Fq 'mkdir -p -- "$LOCAL_FILES/temp"' "$ROOT_DIR/check-updates.sh"
echo 'remote LXC single-check temp-directory regression: PASS'

# A guest hostname is display metadata. If pct exec hostname fails but the
# Proxmox config is readable, the package check must still proceed.
cat > "$WORK_DIR/hostname-fallback.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD/remote-run"
mkdir -p "$LOCAL_FILES"
CONTAINER=230
RDU=false
STATUS_MODEL_NODE=node2
STATUS_MODEL_GUEST_NAME=tasmota
INITIAL_INVENTORY=false
STATUS_MODEL_RECORD_FILE="$PWD/hostname-records"
YL='' CL=''
SANITIZE_NUMBER() { tr -cd '0-9' <<< "$1"; }
READ_APT_UPDATE_COUNTS() { SECURITY_APT_UPDATES=0; NORMAL_APT_UPDATES=0; }
cluster_target_guest_name() { printf 'tasmota\n'; }
STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$STATUS_MODEL_RECORD_FILE"; }
RUN_PCT_COMMAND() {
  local id="$1"; shift
  [[ "$id" == 230 ]]
  if [[ "${1:-}" == hostname ]]; then
    return 1
  fi
  if [[ "${1:-}" == bash && "${2:-}" == -c && "${3:-}" == "apt-get update" ]]; then
    return 0
  fi
  if [[ "${1:-}" == bash && "${2:-}" == -c && "${3:-}" == "apt-get -s upgrade" ]]; then
    printf '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    return 0
  fi
  return 1
}
pct() {
  [[ "$1" == config && "$2" == 230 ]]
  printf 'ostype: debian\nhostname: tasmota\n'
}
source "$PWD/check-container.sh"
CHECK_CONTAINER 230
grep -Fq '230 lxc pct true debian' "$STATUS_MODEL_RECORD_FILE"
! grep -Fq 'CHECK_COMMAND_FAILED' "$STATUS_MODEL_RECORD_FILE"
HARNESS
chmod 750 "$WORK_DIR/hostname-fallback.sh"
(cd "$WORK_DIR" && bash hostname-fallback.sh)
echo 'remote LXC hostname fallback: PASS'
