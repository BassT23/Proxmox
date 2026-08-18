#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^GUEST_INTERNET_PREFLIGHT_COMMAND\(\)/,/^# Wait for bootup/' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/preflight-functions.sh"
awk '/^# Container Check$/,/^## VM ##/' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

LOG_FILE=${LOG_FILE:?}
LOCAL_FILES="$PWD"
mkdir -p "$LOCAL_FILES/temp"
INITIAL_INVENTORY=true
RDU=false
CHECK_URL=example.invalid
EXE_FOR_INTERNET_CHECK=ping
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=fixture-912
BL='' OR='' RD='' GN='' CL=''
ONLY=''
EXCLUDED=''

record() { printf '%s\n' "$*" >> "$LOG_FILE"; }
STATUS_MODEL_RECORD() { record "status $*"; }
SANITIZE_NUMBER() { printf '%s' "$1"; }
cluster_target_guest_name() { printf 'fixture-912\n'; }
CHECK_CONTAINER_FAILURE() { record "failure $*"; return 1; }

pct() {
  case "${1:-}" in
    config) printf 'ostype: debian\n' ;;
    *) return 0 ;;
  esac
}

RUN_PCT_COMMAND() {
  record "pct-exec $*"
  if [[ "$*" == *'ping'* ]]; then
    return 1
  fi
  if [[ "$*" == *'hostname'* ]]; then
    printf 'guest\n'
    return 0
  fi
  record 'PACKAGE_MANAGER_CALLED'
  return 1
}

source "$1/preflight-functions.sh"
source "$1/container-functions.sh"
CHECK_CONTAINER 912 || true

grep -Fq 'status 912 lxc pct false' "$LOG_FILE"
grep -Fq 'NETWORK_UNAVAILABLE' "$LOG_FILE"
if grep -Fq 'PACKAGE_MANAGER_CALLED' "$LOG_FILE"; then
  echo 'package manager was called after failed guest preflight' >&2
  exit 1
fi

# Normal checks retain their existing package-manager behavior.
: > "$LOG_FILE"
INITIAL_INVENTORY=false
CHECK_CONTAINER 912 || true
grep -Fq 'PACKAGE_MANAGER_CALLED' "$LOG_FILE"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

(cd "$WORK_DIR"; LOG_FILE="$WORK_DIR/commands.log" bash "$WORK_DIR/harness.sh" "$WORK_DIR")

grep -Fq 'UU_JOB_SOURCE=initial-inventory REMOTE_JOB_SOURCE=initial-inventory REMOTE_INITIAL_INVENTORY=true' "$ROOT_DIR/check-updates.sh"
grep -Fq "REMOTE_JOB_SOURCE=\${UU_JOB_SOURCE} REMOTE_INITIAL_INVENTORY=\$INITIAL_INVENTORY" "$ROOT_DIR/check-updates.sh"
grep -Fq 'GUEST_INTERNET_PREFLIGHT_PCT' "$ROOT_DIR/check-updates.sh"
grep -Fq 'GUEST_INTERNET_PREFLIGHT_SSH' "$ROOT_DIR/check-updates.sh"
grep -Fq 'GUEST_INTERNET_PREFLIGHT_QGA' "$ROOT_DIR/check-updates.sh"

printf '%s\n' 'initial inventory remote context and guest preflight tests: PASS'
