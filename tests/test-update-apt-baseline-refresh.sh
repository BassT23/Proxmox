#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the production container update function with a stale inherited
# zero.  The fake package check writes a fresh positive observation only after
# the simulated apt-get update, matching the live failure mode without
# contacting a guest or a package manager.
awk '/^CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE\(\) \{/{copy=1} /^# All update result writes go through/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/baseline-functions.sh"
awk '/^UPDATE_CONTAINER \(\) \{/{copy=1} /^# VM Update Start/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-container.sh"

cat > "$WORK_DIR/check.sh" <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
printf 'fresh-check %s %s\n' "$1" "$2" >> "$CHECK_LOG"
checked_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
cat > "$STATUS_MODEL_FILE" <<JSON
{"schema_version":1,"generated_at":"$checked_at","targets":[{"id":"$2","type":"lxc","node":"$STATUS_MODEL_NODE","reachable":true,"check_status":"updates_available","updates":{"available":6},"last_check":"$checked_at","package_checked_at":"$checked_at","package_data_invalidated":false,"package_mutation_in_progress":false}]}
JSON
CHECK
chmod 750 "$WORK_DIR/check.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
SOURCE_DIR=$(dirname -- "$WORK_DIR")
LOCAL_FILES="$WORK_DIR/local"
TEMP_STATE_DIR="$WORK_DIR/temp"
CHECK_SCRIPT="$SOURCE_DIR/check.sh"
STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh"
STATUS_MODEL_NODE=Proxmox-Test-2
STATUS_MODEL_FILE="$WORK_DIR/status.json"
CHECK_LOG="$WORK_DIR/check.log"
EVENTS="$WORK_DIR/events"
mkdir -p "$LOCAL_FILES" "$TEMP_STATE_DIR"
: > "$EVENTS"
: > "$CHECK_LOG"

export CHECK_LOG
export LOCAL_FILES TEMP_STATE_DIR CHECK_SCRIPT STATUS_MODEL_SCRIPT
export STATUS_MODEL_NODE STATUS_MODEL_FILE
export CONFIG_FILE="$WORK_DIR/update.conf"
export TARGET_RUNTIME_FILE="$WORK_DIR/missing-target-runtime.sh"
export CLUSTER_TARGET_FILE="$WORK_DIR/missing-cluster-target.sh"
export INTERNAL_SSH_FILE="$WORK_DIR/missing-internal-ssh.sh"
export QGA_EXEC_SCRIPT="$WORK_DIR/missing-qga.sh"
export WINDOWS_UPDATE_FILE="$WORK_DIR/missing-windows-update.sh"
export APT_COUNT_SCRIPT="$ROOT_DIR/apt-count.py"
export APT_COUNT_SHELL_SCRIPT="$ROOT_DIR/apt-count.sh"
export RPM_COUNT_SCRIPT="$ROOT_DIR/rpm-count.py"
export PACKAGE_COUNT_SCRIPT="$ROOT_DIR/package-count.sh"
export STATUS_MODEL_RECORD_FILE="$WORK_DIR/records"
export STATUS_MODEL_GENERATION_FILE="$WORK_DIR/generations"
export STATUS_MODEL_DIAGNOSTICS_FILE="$WORK_DIR/diagnostics"

UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_RESULT_RECORDED=false
SAFETY_FAILURE=false
ERROR_CODE=""
CCONTAINER=""
CONTAINER=928
OS=debian
CHECK_DIST=false
SCRIPT_ONLY=false
SINGLE_UPDATE=true
ONLY=928
STOPPED_CONTAINER=true
RUNNING_CONTAINER=true
SNAPSHOT=false
BACKUP=false
BACKUP_LXC_MP=false
CHECK_URL_EXE=ping
CHECK_URL=example.invalid
INCLUDE_PHASED_UPDATES=false
DPKG_OPTIONS_STRING=""
APT_FRONTEND_PREFIX=""
UNIFI=""
EFFECTIVE_HEADLESS() { return 0; }
APT_FRONTEND_PREFIX() { :; }
SCRIPT_ONLY_ENABLED() { return 1; }
CONTAINER_BACKUP() { printf 'backup\n' >> "$EVENTS"; return 0; }
REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { printf 'invalidate %s\n' "$*" >> "$EVENTS"; return 0; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { printf 'complete %s\n' "$*" >> "$EVENTS"; return 0; }
UPDATE_TARGET_CAPABILITY_GUARD() { return 0; }
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH() { return 0; }
EXTRAS() { return 0; }
TRIM_FILESYSTEM() { return 0; }
DPKG_REPAIR_PREPARE() { printf 'repair\n' >> "$EVENTS"; return 0; }
ERROR() { UPDATE_FAILURE=true; printf 'error %s\n' "$ERROR_MSG" >> "$EVENTS"; return 0; }
RECORD_UPDATE_RESULT() {
  local target=$1 status=$2 rc=${3:-0}
  printf 'result target=%s status=%s rc=%s pending=%s\n' \
    "$target" "$status" "$rc" "${UPDATE_PENDING_BEFORE[$target]-}" >> "$EVENTS"
  UPDATE_RESULT_RECORDED=true
  RESULT_STATUS=$status
  RESULT_PENDING=${UPDATE_PENDING_BEFORE[$target]-}
  return 0
}
UPDATE_CHECK() {
  printf 'post-check\n' >> "$EVENTS"
  RECORD_UPDATE_RESULT "$CONTAINER" success 0
}
RUN_PCT_COMMAND() {
  local target=$1
  shift
  printf 'pct %s %s\n' "$target" "$*" >> "$EVENTS"
  return 0
}
RUN_UPDATE_COMMAND() {
  UPDATE_STEP_OUTPUT=""
  "$@"
}
pct() {
  case "$1" in
    config) printf 'ostype: debian\n' ;;
    exec)
      target=$2
      shift 2
      printf 'pct-exec %s %s\n' "$target" "$*" >> "$EVENTS"
      if [[ "$*" == *"grep -rnw /etc/apt -e unifi"* ]]; then
        return 1
      fi
      if [[ "$*" == *hostname* ]]; then
        printf 'fixture-host\n'
      fi
      return 0
      ;;
    *) return 0 ;;
  esac
}

declare -A UPDATE_PENDING_BEFORE=([928]=0)
UU_UPDATE_PENDING_BEFORE_TARGET=928
UU_UPDATE_PENDING_BEFORE=0

source "$ROOT_DIR/status-model.sh"
source "$SOURCE_DIR/baseline-functions.sh"
source "$SOURCE_DIR/update-container.sh"

UPDATE_CONTAINER 928

[[ "$RESULT_STATUS" == success ]]
[[ "$RESULT_PENDING" == 6 ]]
[[ "$UPDATE_WARNING" == false ]]
[[ "$UPDATE_FAILURE" == false ]]
[[ "$(grep -c '^fresh-check ccontainer 928$' "$CHECK_LOG")" == 1 ]]

apt_line=$(grep -n 'apt-get update' "$EVENTS" | head -n1 | cut -d: -f1)
repair_line=$(grep -n '^repair$' "$EVENTS" | head -n1 | cut -d: -f1)
upgrade_line=$(grep -n 'apt-get.*dist-upgrade' "$EVENTS" | head -n1 | cut -d: -f1)
[[ -n "$apt_line" && -n "$repair_line" && -n "$upgrade_line" ]]
(( apt_line < repair_line && repair_line < upgrade_line ))

echo 'APT baseline refresh before positive mutation: PASS'
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

"$WORK_DIR/harness.sh" "$ROOT_DIR" "$WORK_DIR/case"
