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
cluster_target_guest_name() { printf 'smarthome-service\n'; }
STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$STATUS_MODEL_RECORD_FILE"; }
RUN_PCT_COMMAND() {
  local id="$1"; shift
  [[ "$id" == 200 ]]
  [[ "${1:-}" == hostname ]] && printf 'smarthome-service\n'
  return 0
}
pct() {
  [[ "$1" == config && "$2" == 200 ]]
  printf 'ostype: unsupported\n'
}
source "$PWD/check-container.sh"
CHECK_CONTAINER 200
test -f "$LOCAL_FILES/temp/temp"
grep -Fq '200 lxc pct true unsupported' "$STATUS_MODEL_RECORD_FILE"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"
(cd "$WORK_DIR" && bash harness.sh)

# Match the shell parameter syntax literally in the source assertion.
# shellcheck disable=SC2016
grep -Fq 'mkdir -p -- "$LOCAL_FILES/temp"' "$ROOT_DIR/check-updates.sh"
echo 'remote LXC single-check temp-directory regression: PASS'
