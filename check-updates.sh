#!/bin/bash

#################
# Check Updates #
#################

# shellcheck disable=SC2034,SC2086,SC2317

VERSION="2.1"

CHECK_FAILURE=0
INITIAL_INVENTORY=false
[[ "${UU_JOB_SOURCE:-}" == initial-inventory ]] && INITIAL_INVENTORY=true

#Variable / Function
# LOCAL_FILES may intentionally point at the run-scoped helper directory used
# by central remote checks; the legacy path consumers below are kept intact.
LOCAL_FILES="${LOCAL_FILES:-/etc/ultimate-updater}"
CONFIG_FILE="${CONFIG_FILE:-$LOCAL_FILES/update.conf}"

TARGET_RUNTIME_FILE="${TARGET_RUNTIME_FILE:-$LOCAL_FILES/target-runtime.sh}"
if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$TARGET_RUNTIME_FILE"
else
  # These indirect transport calls are used by the legacy-compatible paths
  # below when an older installation has no shared runtime helper yet.
  # shellcheck disable=SC2317,SC2329
  RUN_LOCAL_COMMAND() { "$@"; }
  RUN_PCT_COMMAND() { local target_id="$1"; shift; timeout "${UU_CHECK_PCT_COMMAND_TIMEOUT:-120}" pct exec "$target_id" -- "$@"; }
  # Checks must fail fast for offline fixtures.  The update/dispatch runtime
  # keeps its separate, longer SSH and pct-exec timeouts in target-runtime.sh.
  # shellcheck disable=SC2317,SC2329
  RUN_SSH_COMMAND() { local host="$1" port="$2" user="$3"; shift 3; timeout "${UU_CHECK_SSH_COMMAND_TIMEOUT:-15}" ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"; }
  READ_APT_UPDATE_COUNTS() {
    SECURITY_APT_UPDATES=$(printf '%s\n' "$1" | grep -ci '^inst.*security' || true)
    NORMAL_APT_UPDATES=$(printf '%s\n' "$1" | grep -ci '^inst.' || true)
  }
fi

# The shared runtime helper deliberately keeps a longer timeout for update
# dispatches.  A check must use its own short timeout for offline fixtures.
# shellcheck disable=SC2317,SC2329
RUN_SSH_COMMAND() {
  local host="$1" port="$2" user="$3"
  shift 3
  timeout "${UU_CHECK_SSH_COMMAND_TIMEOUT:-15}" ssh "${INTERNAL_SSH_ARGS[@]}" -p "$port" "$user@$host" "$@"
}

CLUSTER_TARGET_FILE="${CLUSTER_TARGET_FILE:-$LOCAL_FILES/cluster-target.sh}"
if [[ -f "$CLUSTER_TARGET_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$CLUSTER_TARGET_FILE"
fi

INTERNAL_SSH_FILE="${INTERNAL_SSH_FILE:-$LOCAL_FILES/internal-ssh.sh}"
if [[ -f "$INTERNAL_SSH_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$INTERNAL_SSH_FILE"
else
  INTERNAL_SSH_ARGS=()
  INTERNAL_SSH_USE_IDENTITY() { :; }
  INTERNAL_SSH_RESOLVE_NODE() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER=root; INTERNAL_SSH_PORT="${3:-22}"; }
  INTERNAL_SSH_RESOLVE_VM() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER="$3"; INTERNAL_SSH_PORT="${4:-22}"; }
fi

STATUS_MODEL_SCRIPT="${STATUS_MODEL_SCRIPT:-$LOCAL_FILES/status-model.sh}"
WINDOWS_UPDATE_FILE="${WINDOWS_UPDATE_FILE:-$LOCAL_FILES/windows-update.sh}"
if [[ -f "$WINDOWS_UPDATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$WINDOWS_UPDATE_FILE"
fi

# Optional additive machine-readable status output. Older installations can
# continue without the helper until their next updater update.
if [[ -f "$STATUS_MODEL_SCRIPT" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$STATUS_MODEL_SCRIPT"
else
  STATUS_MODEL_INIT() { :; }
  STATUS_MODEL_RECORD() { :; }
  STATUS_MODEL_IMPORT_FILE() { :; }
  STATUS_MODEL_FINISH() { :; }
fi

STATUS_MODEL_DIAGNOSTIC() {
  local message="$*"
  if [[ -n "${STATUS_MODEL_DIAGNOSTICS_FILE:-}" ]]; then
    printf '%s\n' "$message" >> "$STATUS_MODEL_DIAGNOSTICS_FILE" 2>/dev/null || true
  fi
  if [[ "${DEBUG:-false}" == true ]]; then
    printf '%s\n' "$message" >&2
  fi
}

# Central remote phases must remain visible even when the optional diagnostic
# file is not configured. Prefer the structured journal; otherwise use the
# central job log via stderr. Never emit these markers from the remote shell.
CENTRAL_REMOTE_PHASE() {
  local message="$*"
  STATUS_MODEL_DIAGNOSTIC "$message"
  if [[ -z "${STATUS_MODEL_DIAGNOSTICS_FILE:-}" && "${DEBUG:-false}" != true ]]; then
    printf '%s\n' "$message" >&2
  fi
}

# Tag filter
TAG_FILTER_FILE="${TAG_FILTER_FILE:-$LOCAL_FILES/tag-filter.sh}"
# shellcheck disable=SC1090,SC1091
. "$TAG_FILTER_FILE"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

SANITIZE_NUMBER() {
  echo "$1" | tr -cd '0-9'
}

# Decode one structured qm guest exec response without losing the guest
# exitcode. The qm CLI itself can return zero when only the guest command
# failed, so transport and guest status are kept separate.
QEMU_GUEST_EXEC () {
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=""
  QEMU_EXEC_TRANSPORT_RC=0
  local QEMU_RAW QEMU_PARSED QEMU_STATUS

  QEMU_RAW=$(qm guest exec "$@" 2>&1)
  QEMU_STATUS=$?
  if [[ $QEMU_STATUS -ne 0 ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=$QEMU_STATUS
    return 0
  fi

  if ! QEMU_PARSED=$(printf '%s' "$QEMU_RAW" | python3 -c '
import base64
import json
import sys

try:
    response = json.load(sys.stdin)
except (TypeError, ValueError):
    sys.exit(1)

for key in ("out-data", "err-data"):
    value = response.get(key, "")
    if not isinstance(value, str):
        value = str(value)
    print(base64.b64encode(value.encode()).decode())

exitcode = response.get("exitcode", 0)
if not isinstance(exitcode, int) or exitcode < 0:
    sys.exit(1)
print(exitcode)
'); then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi

  local -a QEMU_FIELDS
  mapfile -t QEMU_FIELDS <<< "$QEMU_PARSED"
  if [[ ${#QEMU_FIELDS[@]} -ne 3 || ! ${QEMU_FIELDS[2]} =~ ^[0-9]+$ ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi
  IFS= read -r -d '' QEMU_EXEC_STDOUT < <(printf '%s' "${QEMU_FIELDS[0]}" | base64 -d) || true
  IFS= read -r -d '' QEMU_EXEC_STDERR < <(printf '%s' "${QEMU_FIELDS[1]}" | base64 -d) || true
  QEMU_EXEC_EXITCODE=${QEMU_FIELDS[2]}
  if [[ -n "$QEMU_EXEC_STDOUT" && -n "$QEMU_EXEC_STDERR" ]]; then
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}
${QEMU_EXEC_STDERR}"
  else
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}${QEMU_EXEC_STDERR}"
  fi
  return 0
}

QEMU_COUNT_RESULT_OK () {
  local QEMU_COUNT_LABEL="$1"
  local QEMU_COUNT_ZERO=false
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    echo -e "${RD}${QEMU_COUNT_LABEL} failed: ${QEMU_EXEC_OUTPUT}${CL}"
    return 1
  fi
  # grep -c returns 1 for zero matches. That is the only non-zero guest
  # status accepted for numeric update-count commands; all other failures
  # must remain visible instead of being treated as zero updates.
  if [[ "$QEMU_EXEC_EXITCODE" -eq 1 && "$QEMU_EXEC_STDOUT" =~ ^[[:space:]]*0[[:space:]]*$ && -z "$QEMU_EXEC_STDERR" ]]; then
    QEMU_COUNT_ZERO=true
  fi
  if [[ "$QEMU_EXEC_EXITCODE" -ne 0 && "$QEMU_COUNT_ZERO" != true ]]; then
    echo -e "${RD}${QEMU_COUNT_LABEL} failed (guest exit code $QEMU_EXEC_EXITCODE): ${QEMU_EXEC_OUTPUT}${CL}"
    return 1
  fi
  return 0
}

ARGUMENTS () {
  local check_rc
  while [[ $# -gt 0 ]]; do
    local ARGUMENT="$1"
    case "$ARGUMENT" in
      -c) RICM=true ;;
      -u) RDU=true ;;
      chost)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_HOST_ITSELF || CHECK_FAILURE=1
        ;;
      node-host)
        # Dedicated explicit node-check entry point. This path cannot
        # expand into guest checks, regardless of update.conf guest flags.
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_HOST_ITSELF || CHECK_FAILURE=1
        ;;
      ccontainer)
        COMMAND=true
        OUTPUT_TO_FILE
        if [[ -n "${2:-}" ]]; then
          if CHECK_CONTAINER "$2"; then check_rc=0; else check_rc=$?; fi
          shift
        else
          if CHECK_CONTAINER; then check_rc=0; else check_rc=$?; fi
        fi
        [[ "$check_rc" -eq 0 ]] || CHECK_FAILURE=1
        ;;
      cvm)
        COMMAND=true
        OUTPUT_TO_FILE
        if [[ -n "${2:-}" ]]; then
          if CHECK_VM "$2"; then check_rc=0; else check_rc=$?; fi
          shift
        else
          if CHECK_VM; then check_rc=0; else check_rc=$?; fi
        fi
        [[ "$check_rc" -eq 0 ]] || CHECK_FAILURE=1
        ;;
      host)
        COMMAND=true
        OUTPUT_TO_FILE
        if [[ "$WITH_HOST" == true ]]; then CHECK_HOST_ITSELF; fi
        # An explicit node check is a host observation, even when the
        # global configuration enables guest checks.  The configured guest
        # scope belongs to the full/automatic check path only.
        if [[ "${UU_CHECK_SCOPE:-}" != host && "$WITH_LXC" == true ]]; then CONTAINER_CHECK_START; fi
        if [[ "${UU_CHECK_SCOPE:-}" != host && "$WITH_VM" == true ]]; then VM_CHECK_START; fi
        ;;
      cluster)
        COMMAND=true
        OUTPUT_TO_FILE
        HOST_CHECK_START
        ;;
      *)
        echo -e "\n${RD}  Error: Got an unexpected argument \"$ARGUMENT\"${CL}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}

# Usage
USAGE () {
  echo -e "\nUsage: $0 {COMMAND}\n"
  echo -e "{COMMAND}:"
  echo -e "========="
  echo -e "  host                 Host-Mode"
  echo -e "  cluster              Cluster-Mode\n"
  echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
}


READ_WRITE_CONFIG () {
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' $CONFIG_FILE)
  EMAIL_USER=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' $CONFIG_FILE)
  EMAIL_SENDER=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' $CONFIG_FILE)
  EMAIL_DAILY_CHECK=$(awk -F'"' '/^EMAIL_DAILY_CHECK=/ {print $2}' $CONFIG_FILE)
  EMAIL_NO_UPDATES=$(awk -F'"' '/^EMAIL_NO_UPDATES=/ {print $2}' $CONFIG_FILE)
  EMAIL_ONLY_SECURITY=$(awk -F'"' '/^EMAIL_ONLY_SECURITY=/ {print $2}' $CONFIG_FILE)
  EMAIL_USER="${EMAIL_USER:-root}"
  EMAIL_SENDER="${EMAIL_SENDER:-$USER}"
  if declare -f STATUS_MODEL_EXPAND_SENDER >/dev/null 2>&1; then
    EMAIL_SENDER=$(STATUS_MODEL_EXPAND_SENDER "$EMAIL_SENDER")
  fi
  EMAIL_DAILY_CHECK="${EMAIL_DAILY_CHECK:-true}"
  EMAIL_NO_UPDATES="${EMAIL_NO_UPDATES:-false}"
  EMAIL_ONLY_SECURITY="${EMAIL_ONLY_SECURITY:-false}"
  WITH_HOST=$(awk -F'"' '/^CHECK_WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  RUNNING_VM=$(awk -F'"' '/^CHECK_RUNNING_VM=/ {print $2}' $CONFIG_FILE)
  STOPPED_VM=$(awk -F'"' '/^CHECK_STOPPED_VM=/ {print $2}' $CONFIG_FILE)
  PAUSED_VM=$(awk -F'"' '/^CHECK_PAUSED_VM=/ {print $2}' $CONFIG_FILE)
  REBOOT_IF_NEEDED=$(awk -F'"' '/^REBOOT_IF_NEEDED=/ {print $2}' "$CONFIG_FILE")
  REBOOT_IF_NEEDED="${REBOOT_IF_NEEDED:-true}"
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  CHECK_URL=$(awk -F '"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' $CONFIG_FILE)
  EXE_FOR_INTERNET_CHECK=$(awk -F '"' '/^EXE_FOR_INTERNET_CHECK=/ {print $2}' $CONFIG_FILE)
  EXE_FOR_INTERNET_CHECK="${EXE_FOR_INTERNET_CHECK:-ping}"
  LXC_START_DELAY=$(awk -F'"' '/^LXC_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  LXC_START_DELAY=$(SANITIZE_NUMBER "$LXC_START_DELAY")
  LXC_START_DELAY="${LXC_START_DELAY:-5}"
  VM_START_DELAY=$(awk -F'"' '/^VM_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  VM_START_DELAY=$(SANITIZE_NUMBER "$VM_START_DELAY")
  VM_START_DELAY="${VM_START_DELAY:-45}"

  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    export UU_FILTER_SCOPE=check
    apply_only_exclude_tags ONLY EXCLUDED
  fi
}

# Initial inventory must avoid invoking a package manager in a guest that has
# no network access.  Keep this preflight inside the guest transport and only
# use it for the read-only onboarding mode; normal checks retain their
# established semantics.
GUEST_INTERNET_PREFLIGHT_COMMAND() {
  local executable="${EXE_FOR_INTERNET_CHECK:-ping}" url="${CHECK_URL:-}"
  local executable_q url_q
  [[ -n "$url" ]] || return 1
  printf -v executable_q '%q' "$executable"
  printf -v url_q '%q' "$url"
  printf '%s -q -c1 %s >/dev/null 2>&1' "$executable_q" "$url_q"
}

GUEST_INTERNET_PREFLIGHT_PCT() {
  local command
  command=$(GUEST_INTERNET_PREFLIGHT_COMMAND) || return 1
  UU_CHECK_PCT_COMMAND_TIMEOUT="${UU_GUEST_PREFLIGHT_TIMEOUT:-5}" \
    RUN_PCT_COMMAND "$1" bash -c "$command"
}

GUEST_INTERNET_PREFLIGHT_SSH() {
  local command
  command=$(GUEST_INTERNET_PREFLIGHT_COMMAND) || return 1
  UU_CHECK_SSH_COMMAND_TIMEOUT="${UU_GUEST_PREFLIGHT_TIMEOUT:-5}" \
    RUN_SSH_COMMAND "$1" "$2" "$3" "$command"
}

GUEST_INTERNET_PREFLIGHT_QGA() {
  local command
  command=$(GUEST_INTERNET_PREFLIGHT_COMMAND) || return 1
  QEMU_GUEST_EXEC "$1" --timeout "${UU_GUEST_PREFLIGHT_TIMEOUT:-5}" -- bash -c "$command"
  [[ "$QEMU_EXEC_TRANSPORT_RC" -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]
}

# Wait for bootup / reboot
# Container
WAIT_FOR_BOOTUP_LXC () {
  MAX_RETRIES=10
  COUNT=1
  sleep "$LXC_START_DELAY"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if timeout 10 pct exec "$CONTAINER" -- bash -c "exit" >/dev/null 2>&1; then
      break
    else
      sleep "$LXC_START_DELAY"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    return 1
  fi
}

WAIT_FOR_QGA () {
  local attempts=15 interval=2
  while (( attempts > 0 )); do
    if timeout 10 qm agent "$VM" ping >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep "$interval"
  done
  echo -e "${RD}QEMU Guest Agent did not become ready for VM $VM${CL}"
  return 1
}

## HOST ##
# Resolve a cluster member's stable node name before attempting SSH.  HOSTS is
# intentionally kept as the corosync ring address list for the existing
# transport path, but status identity must not change when a node is offline.
CLUSTER_HOST_NODE () {
  local host="$1"
  if [[ -f /etc/pve/corosync.conf ]]; then
    awk -v address="$host" '
      /name[[:space:]]*:/ { name=$2 }
      /ring0_addr[[:space:]]*:/ && $2 == address { print name; found=1; exit }
      END { if (!found) print address }
    ' /etc/pve/corosync.conf
  else
    printf '%s\n' "$host"
  fi
}

# Host Check Start
HOST_IS_LOCAL () {
  local candidate="$1" local_address
  [[ "$candidate" == "$HOSTNAME" || "$candidate" == "$(hostname -s 2>/dev/null)" ||
    "$candidate" == "$(hostname -f 2>/dev/null)" ]] && return 0
  for local_address in $(hostname -I 2>/dev/null); do
    [[ "$candidate" == "$local_address" ]] && return 0
  done
  return 1
}

# Bound only the remote setup/transfer operations used while preparing a
# cluster host check.  ConnectTimeout limits TCP connection establishment, but
# it does not stop an SSH/SCP command that connected and then stopped
# responding (for example an offline cluster fixture with a stale route).
CHECK_REMOTE_SSH () {
  timeout "${UU_CHECK_SSH_COMMAND_TIMEOUT:-15}" ssh "${INTERNAL_SSH_ARGS[@]}" "$@"
}

CHECK_REMOTE_SCP () {
  local scp_args=()
  if [[ -n "${INTERNAL_SSH_IDENTITY_FILE:-}" ]]; then scp_args=(-o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -i "$INTERNAL_SSH_IDENTITY_FILE"); fi
  timeout "${UU_CHECK_SSH_COMMAND_TIMEOUT:-15}" scp "${scp_args[@]}" "$@"
}

# A remote check contains the complete read-only host/guest inspection.  The
# timeout for that inspection is applied inside the remote wrapper.  The SSH
# session itself gets a separate, slightly longer wrapper budget so the
# status-model finalization and completion marker can still run after an
# inner timeout.
CHECK_REMOTE_JOB_SSH () {
  local job_timeout="${UU_CHECK_REMOTE_JOB_TIMEOUT:-300}"
  local wrapper_timeout="${UU_CHECK_REMOTE_WRAPPER_TIMEOUT:-$((job_timeout + 60))}"
  timeout "$wrapper_timeout" ssh "${INTERNAL_SSH_ARGS[@]}" "$@"
}

# Keep remote artifact diagnostics in the job log without exposing command
# output, credentials, or SSH material.  Normal successful runs stay quiet;
# DEBUG or a retrieval failure includes the complete correlation data.
REMOTE_STATUS_DIAGNOSTICS () {
  local level="$1" node="$2" host="$3" run_dir="$4" done_file="$5" status_path="$6"
  local done_found="$7" done_value="$8" status_found="$9" status_size="${10}"
  local completion_transport_rc="${11}" status_transport_rc="${12}" json_result="${13}" cleanup_state="${14}" classification="${15}"
  local diagnostic_found="${16}" diagnostic_size="${17}" diagnostic_transport_rc="${18}"
  [[ "$level" == failure || "${DEBUG:-false}" == true ]] || return 0
  printf 'Remote status diagnostics: node=%s host=%s run=%s remote_dir=%s completion=%s completion_found=%s remote_rc=%s status_file=%s status_found=%s status_size=%s completion_transport_rc=%s status_transport_rc=%s json=%s classification=%s diagnostic_found=%s diagnostic_size=%s diagnostic_transport_rc=%s cleanup=%s\n' \
    "$node" "$host" "$(basename -- "$run_dir")" "$run_dir" "$done_file" \
    "$done_found" "${done_value:-unknown}" "$status_path" "$status_found" \
    "$status_size" "$completion_transport_rc" "$status_transport_rc" "$json_result" "$classification" \
    "$diagnostic_found" "$diagnostic_size" "$diagnostic_transport_rc" "$cleanup_state"
}

HOST_CHECK_START () {
  for HOST in $HOSTS; do
    if HOST_IS_LOCAL "$HOST"; then
      CHECK_HOST_ITSELF
      if [[ "$WITH_LXC" == true ]]; then CONTAINER_CHECK_START; fi
      if [[ "$WITH_VM" == true ]]; then VM_CHECK_START; fi
    else
      if ! CHECK_HOST "$HOST"; then
        CHECK_FAILURE=1
      fi
    fi
  done
}

# Host Check
CHECK_HOST () {
  local HOST=$1 remote_check_dir remote_status remote_status_file remote_done_file
  local remote_done_value remote_status_attempt HOST_NODE HOST_ID remote_done_error_file remote_status_error_file remote_diagnostics_error_file
  local remote_diagnostics_file remote_diagnostics_local_file remote_diagnostics_attempt
  local remote_done_found=false remote_done_transport_rc=0 remote_status_transport_rc=0
  local remote_diagnostics_found=false remote_diagnostics_size=0 remote_diagnostics_transport_rc=0
  local remote_status_found=false remote_status_size=0 remote_json_result=not-checked
  local remote_job_timeout="${UU_CHECK_REMOTE_JOB_TIMEOUT:-300}"
  local remote_cleanup_state=pending remote_diag_level=success remote_failure_class=none
  HOST_NODE=$(CLUSTER_HOST_NODE "$HOST")
  CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_START node=$HOST_NODE host=$HOST"
  if ! INTERNAL_SSH_RESOLVE_NODE "$HOST_NODE" "$HOST" "$SSH_PORT"; then
    CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=1 phase=resolve"
    return 1
  fi
  if [[ "${INTERNAL_SSH_ENABLED:-true}" != true ]]; then
    CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=1 phase=disabled"
    return 1
  fi
  HOST="${INTERNAL_SSH_HOST:-$HOST}"; SSH_PORT="${INTERNAL_SSH_PORT:-$SSH_PORT}"
  INTERNAL_SSH_USE_IDENTITY
  HOST_ID="host:$HOST_NODE"
  # The central shell PID alone is not a sufficient remote-job identity when
  # checks overlap or are retried.  Keep the artifact private to this one
  # dispatch and let the remote wrapper signal completion explicitly.
  remote_check_dir="/tmp/ultimate-updater-check-${$}-${RANDOM}-${RANDOM}"
  remote_done_file="$remote_check_dir/completed"
  remote_runtime_env=""
  remote_status_env=""
  remote_status_validation=""
  remote_status_file="/tmp/ultimate-updater-remote-status-$$-$RANDOM.json"
  remote_diagnostics_file="$remote_check_dir/status-diagnostics"
  remote_diagnostics_local_file="/tmp/ultimate-updater-remote-diagnostics-$$-$RANDOM.log"
  remote_done_error_file="${remote_status_file}.completion.err"
  remote_status_error_file="${remote_status_file}.status.err"
  remote_diagnostics_error_file="${remote_status_file}.diagnostics.err"
  if ! CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "mkdir -p '$LOCAL_FILES' '$remote_check_dir'" ||
    ! CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$LOCAL_FILES/update.conf" "$HOST:$LOCAL_FILES/update.conf" >/dev/null 2>&1 ||
    ! CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$TAG_FILTER_FILE" "$HOST:$remote_check_dir/tag-filter.sh" >/dev/null 2>&1; then
    CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
    echo -e "${RD}Could not prepare matching check helper on remote host $HOST${CL}"
    STATUS_MODEL_RECORD "$HOST_ID" host ssh false "" "" "null" "null" offline SSH_UNREACHABLE "Could not prepare remote check" "$HOST_NODE"
    CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=1 phase=prepare"
    return 1
  fi
  if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
    if ! CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$TARGET_RUNTIME_FILE" "$HOST:$remote_check_dir/target-runtime.sh" >/dev/null 2>&1; then
      CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
      echo -e "${RD}Could not prepare target runtime helper on remote host $HOST${CL}"
      STATUS_MODEL_RECORD "$HOST_ID" host ssh false "" "" "null" "null" offline SSH_UNREACHABLE "Could not prepare remote target runtime" "$HOST_NODE"
      CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=1 phase=prepare-target-runtime"
      return 1
    fi
    remote_runtime_env=" TARGET_RUNTIME_FILE='$remote_check_dir/target-runtime.sh'"
  fi
  if [[ -f "$STATUS_MODEL_SCRIPT" ]]; then
    if ! CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$STATUS_MODEL_SCRIPT" "$HOST:$remote_check_dir/status-model.sh" >/dev/null 2>&1; then
      CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
      echo -e "${RD}Could not prepare matching status helper on remote host $HOST${CL}"
      STATUS_MODEL_RECORD "$HOST_ID" host ssh false "" "" "null" "null" offline SSH_UNREACHABLE "Could not prepare remote status helper" "$HOST_NODE"
      CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=1 phase=prepare-status-helper"
      return 1
    fi
    remote_status_env=" STATUS_MODEL_NODE='$HOST_NODE' STATUS_MODEL_SCRIPT='$remote_check_dir/status-model.sh' STATUS_MODEL_FILE='$remote_check_dir/status.json' STATUS_MODEL_RECORD_FILE='$remote_check_dir/status.records' STATUS_MODEL_DIAGNOSTICS_FILE='$remote_diagnostics_file'"
    remote_status_validation=" if [[ \"\$remote_rc\" -eq 0 && ! -s '$remote_check_dir/status.json' ]]; then remote_rc=86; elif [[ \"\$remote_rc\" -eq 0 ]] && ! python3 -c 'import json,sys; payload=json.load(open(sys.argv[1], encoding=\"utf-8\")); assert isinstance(payload, dict) and isinstance(payload.get(\"targets\"), list)' '$remote_check_dir/status.json'; then remote_rc=87; fi;"
  fi
  if [[ "${UU_JOB_SOURCE:-}" == initial-inventory ]]; then
    # The remote check derives its lifecycle-safe mode from this explicit
    # job context. Never infer it from the command name.
    remote_status_env=" UU_JOB_SOURCE=initial-inventory REMOTE_JOB_SOURCE=initial-inventory REMOTE_INITIAL_INVENTORY=true$remote_status_env"
  fi
  if CHECK_REMOTE_JOB_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" \
    "printf '%s\\n' \"REMOTE_CHECK_START node=$HOST_NODE\" >> '$remote_diagnostics_file'; UU_DEFER_NOTIFICATION=true UU_REMOTE_DEFER_STATUS_FINISH=true UU_CHECK_SCOPE=host TAG_FILTER_FILE='$remote_check_dir/tag-filter.sh'$remote_runtime_env$remote_status_env timeout '$remote_job_timeout' bash -s -- node-host; remote_rc=\$?; printf '%s\\n' \"REMOTE_CHECK_RETURN node=$HOST_NODE rc=\$remote_rc\" >> '$remote_diagnostics_file'; finish_rc=0; finish_error_file='$remote_check_dir/status-finish.error'; printf '%s\\n' \"STATUS_MODEL_FINISH_START node=$HOST_NODE script=$remote_check_dir/status-model.sh file=$remote_check_dir/status.json records=$remote_check_dir/status.records\" >> '$remote_diagnostics_file'; if [[ -f '$remote_check_dir/status-model.sh' ]]; then STATUS_MODEL_NODE='$HOST_NODE'; STATUS_MODEL_FILE='$remote_check_dir/status.json'; STATUS_MODEL_RECORD_FILE='$remote_check_dir/status.records'; . '$remote_check_dir/status-model.sh'; STATUS_MODEL_FINISH >/dev/null 2>\"\$finish_error_file\" || finish_rc=\$?; else finish_rc=1; printf '%s\\n' 'status-model script missing' > \"\$finish_error_file\"; fi; finish_reason=none; if [[ -s \"\$finish_error_file\" ]]; then finish_reason=\$(tr '\\n' ' ' < \"\$finish_error_file\" | cut -c1-500); fi; finish_exists=false; [[ -s '$remote_check_dir/status.json' ]] && finish_exists=true; finish_size=0; [[ -e '$remote_check_dir/status.json' ]] && finish_size=\$(stat -c '%s' '$remote_check_dir/status.json' 2>/dev/null || printf '0'); printf '%s\\n' \"STATUS_MODEL_FINISH_END node=$HOST_NODE rc=\$finish_rc exists=\$finish_exists size=\$finish_size reason=\$finish_reason\" >> '$remote_diagnostics_file'; if [[ \"\$remote_rc\" -eq 0 && \"\$finish_rc\" -ne 0 ]]; then remote_rc=\$finish_rc; fi;$remote_status_validation printf '%s\\n' \"COMPLETION_WRITE node=$HOST_NODE rc=\$remote_rc\" >> '$remote_diagnostics_file'; printf '%s\\n' \"\$remote_rc\" > '$remote_done_file'; rm -f -- \"\$finish_error_file\"; exit \"\$remote_rc\"" < "$0"; then
    remote_status=0
  else
    remote_status=$?
  fi
  CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_SSH_RETURN node=$HOST_NODE rc=$remote_status"
  CENTRAL_REMOTE_PHASE "CENTRAL_COMPLETION_FETCH_START node=$HOST_NODE"
  remote_done_value=""
  for remote_status_attempt in 1 2 3; do
    remote_done_transport_rc=0
    remote_done_value=$(CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "cat -- '$remote_done_file'" 2>"$remote_done_error_file") || remote_done_transport_rc=$?
    if [[ "$remote_done_value" =~ ^[0-9]+$ ]]; then
      remote_done_found=true
      break
    fi
    sleep 0.2
  done
  CENTRAL_REMOTE_PHASE "CENTRAL_COMPLETION_FETCH_END node=$HOST_NODE rc=$remote_done_transport_rc found=$remote_done_found value=${remote_done_value:-unknown}"
  if [[ -n "$remote_done_value" && "$remote_done_value" != "$remote_status" ]]; then
    remote_status="$remote_done_value"
  fi
  CENTRAL_REMOTE_PHASE "CENTRAL_STATUS_FETCH_START node=$HOST_NODE"
  for remote_status_attempt in 1 2 3; do
    remote_status_transport_rc=0
    if CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$HOST:$remote_check_dir/status.json" "$remote_status_file" > /dev/null 2>"$remote_status_error_file"; then
      remote_status_transport_rc=0
      break
    fi
    remote_status_transport_rc=$?
    [[ "$remote_status_attempt" -lt 3 ]] && sleep 0.2
  done
  local remote_status_file_found=false
  [[ -e "$remote_status_file" ]] && remote_status_file_found=true
  CENTRAL_REMOTE_PHASE "CENTRAL_STATUS_FETCH_END node=$HOST_NODE rc=$remote_status_transport_rc found=$remote_status_file_found"
  CENTRAL_REMOTE_PHASE "CENTRAL_DIAGNOSTICS_FETCH_START node=$HOST_NODE"
  for remote_diagnostics_attempt in 1 2 3; do
    remote_diagnostics_transport_rc=0
    if CHECK_REMOTE_SCP -q -o BatchMode=yes -o ConnectTimeout=5 -P "$SSH_PORT" "$HOST:$remote_diagnostics_file" "$remote_diagnostics_local_file" > /dev/null 2>"$remote_diagnostics_error_file"; then
      remote_diagnostics_transport_rc=0
      break
    fi
    remote_diagnostics_transport_rc=$?
    [[ "$remote_diagnostics_attempt" -lt 3 ]] && sleep 0.2
  done
  local remote_diagnostics_file_found=false
  [[ -e "$remote_diagnostics_local_file" ]] && remote_diagnostics_file_found=true
  CENTRAL_REMOTE_PHASE "CENTRAL_DIAGNOSTICS_FETCH_END node=$HOST_NODE rc=$remote_diagnostics_transport_rc found=$remote_diagnostics_file_found"
  if [[ -e "$remote_diagnostics_local_file" ]]; then
    remote_diagnostics_found=true
    remote_diagnostics_size=$(stat -c '%s' "$remote_diagnostics_local_file" 2>/dev/null || printf '0')
  fi
  if [[ -e "$remote_status_file" ]]; then
    remote_status_found=true
    remote_status_size=$(stat -c '%s' "$remote_status_file" 2>/dev/null || printf '0')
  fi
  if [[ -s "$remote_status_file" ]]; then
    if ! STATUS_MODEL_IMPORT_FILE "$remote_status_file"; then
      remote_json_result=invalid
      remote_diag_level=failure
      remote_failure_class=invalid-json
      echo -e "${RD}$HOST_NODE ($HOST): remote check status was invalid and could not be imported.${CL}"
      STATUS_MODEL_RECORD "$HOST_ID" host ssh true "" "" "null" "null" error REMOTE_STATUS_IMPORT_FAILED "$HOST_NODE ($HOST): remote check status was invalid and could not be imported" "$HOST_NODE"
    else
      remote_json_result=valid
    fi
    rm -f -- "$remote_status_file"
  elif [[ "$remote_status" -eq 0 ]]; then
    remote_diag_level=failure
    if [[ "$remote_done_found" != true ]]; then
      if [[ "$remote_done_transport_rc" -eq 124 ]]; then
        remote_failure_class=timeout
      elif grep -qiE 'permission denied|access denied' "$remote_done_error_file" 2>/dev/null; then
        remote_failure_class=permission-denied
      elif [[ "$remote_done_transport_rc" -ne 0 ]]; then
        remote_failure_class=ssh-retrieval-failed
      else
        remote_failure_class=completion-marker-missing
      fi
    elif [[ "$remote_status_transport_rc" -eq 124 ]]; then
      remote_failure_class=timeout
    elif grep -qiE 'permission denied|access denied' "$remote_status_error_file" 2>/dev/null; then
      remote_failure_class=permission-denied
    elif [[ "$remote_status_transport_rc" -ne 0 ]]; then
      remote_failure_class=scp-retrieval-failed
    else
      remote_failure_class=status-file-missing
    fi
    echo -e "${RD}$HOST_NODE ($HOST): remote check completed but status result could not be retrieved.${CL}"
    STATUS_MODEL_RECORD "$HOST_ID" host ssh true "" "" "null" "null" error REMOTE_STATUS_IMPORT_FAILED "$HOST_NODE ($HOST): remote check completed but status result could not be retrieved" "$HOST_NODE"
  else
    remote_json_result=not-retrieved
    remote_failure_class=remote-rc-nonzero
  fi
  if [[ "$remote_done_found" != true ]]; then
    remote_diag_level=failure
    if [[ "$remote_done_transport_rc" -eq 124 ]]; then
      remote_failure_class=timeout
    elif grep -qiE 'permission denied|access denied' "$remote_done_error_file" 2>/dev/null; then
      remote_failure_class=permission-denied
    elif [[ "$remote_done_transport_rc" -ne 0 ]]; then
      remote_failure_class=ssh-retrieval-failed
    else
      remote_failure_class=completion-marker-missing
    fi
  fi
  if [[ "$remote_done_found" == true && "$remote_status" -ne 0 ]]; then
    remote_diag_level=failure
    case "$remote_status" in
      86) remote_failure_class=status-file-missing-after-finalization ;;
      87) remote_failure_class=invalid-json-after-finalization ;;
      *) remote_failure_class=remote-rc-nonzero ;;
    esac
  fi
  if [[ ("$remote_diag_level" == failure || "${DEBUG:-false}" == true) && "$remote_diagnostics_found" == true ]]; then
    while IFS= read -r remote_diagnostic_line; do
      [[ -n "$remote_diagnostic_line" ]] || continue
      printf 'Remote status model: node=%s %s\n' "$HOST_NODE" "$remote_diagnostic_line"
    done < "$remote_diagnostics_local_file"
  elif [[ "$remote_diag_level" == failure && "$remote_diagnostics_found" != true ]]; then
    printf 'Remote status model diagnostics unavailable: node=%s transport_rc=%s\n' \
      "$HOST_NODE" "$remote_diagnostics_transport_rc"
  fi
  REMOTE_STATUS_DIAGNOSTICS "$remote_diag_level" "$HOST_NODE" "$HOST" "$remote_check_dir" \
    "$remote_done_file" "$remote_check_dir/status.json" "$remote_done_found" \
    "$remote_done_value" "$remote_status_found" "$remote_status_size" \
    "$remote_done_transport_rc" "$remote_status_transport_rc" "$remote_json_result" "$remote_cleanup_state" "$remote_failure_class" \
    "$remote_diagnostics_found" "$remote_diagnostics_size" "$remote_diagnostics_transport_rc"
  rm -f -- "$remote_status_file"
  rm -f -- "$remote_diagnostics_local_file" "$remote_done_error_file" "$remote_status_error_file" "$remote_diagnostics_error_file"
  CENTRAL_REMOTE_PHASE "CENTRAL_CLEANUP_START node=$HOST_NODE"
  remote_cleanup_state=started
  local remote_cleanup_rc=0
  CHECK_REMOTE_SSH -q -o BatchMode=yes -o ConnectTimeout=5 "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || remote_cleanup_rc=$?
  remote_cleanup_state=completed
  CENTRAL_REMOTE_PHASE "CENTRAL_CLEANUP_END node=$HOST_NODE rc=$remote_cleanup_rc"
  REMOTE_STATUS_DIAGNOSTICS "$remote_diag_level" "$HOST_NODE" "$HOST" "$remote_check_dir" \
    "$remote_done_file" "$remote_check_dir/status.json" "$remote_done_found" \
    "$remote_done_value" "$remote_status_found" "$remote_status_size" \
    "$remote_done_transport_rc" "$remote_status_transport_rc" "$remote_json_result" "$remote_cleanup_state" "$remote_failure_class" \
    "$remote_diagnostics_found" "$remote_diagnostics_size" "$remote_diagnostics_transport_rc"
  if [[ "$remote_status" -ne 0 ]]; then
    STATUS_MODEL_RECORD "$HOST_ID" host ssh true "" "" "null" "null" error REMOTE_CHECK_FAILED "$HOST_NODE ($HOST): remote check exited with $remote_status" "$HOST_NODE"
  fi
  CENTRAL_REMOTE_PHASE "CENTRAL_REMOTE_END node=$HOST_NODE rc=$remote_status phase=complete cleanup_rc=$remote_cleanup_rc"
  return "$remote_status"
}

CHECK_HOST_ITSELF () {
  STATUS_MODEL_GUEST_NAME=""
  REBOOT_REQUIRED=false
  local STATUS_HOST_NAME="${STATUS_MODEL_NODE:-$HOSTNAME}"
  apt-get update >/dev/null 2>&1
  SECURITY_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst.*security" | tr -d '\n')
  if [[ $SECURITY_APT_UPDATES != 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
  NORMAL_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst." | tr -d '\n')
  if [[ -f /var/run/reboot-required || -f /var/run/reboot-required.pkgs ]] ||
    HOST_KERNEL_REBOOT_REQUIRED; then
    REBOOT_REQUIRED=true
  fi
  if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 || $REBOOT_REQUIRED == true ]]; then
    echo -e "\n${BL}Host${CL} : ${GN}$HOSTNAME${CL}"
  fi
  if [[ $REBOOT_REQUIRED == true ]]; then echo -e "${OR} Reboot required${CL}"; fi
  if [[ $SECURITY_APT_UPDATES != 0 && $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
  elif [[ $SECURITY_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / "
  elif [[ $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "N: $NORMAL_APT_UPDATES"
  fi
  local HOST_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
  local HOST_STATUS=ok
  [[ "$HOST_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && HOST_STATUS=updates_available
  local HOST_OS
  HOST_OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
  STATUS_MODEL_RECORD "host:$STATUS_HOST_NAME" host local true "${HOST_OS:-unknown}" apt "$HOST_UPDATES" "${REBOOT_REQUIRED:-false}" "$HOST_STATUS" "" "" "$STATUS_HOST_NAME"
}

# Proxmox kernel packages can install a new bootable kernel without leaving
# Debian's /var/run/reboot-required marker.  Compare the currently running
# kernel with the newest kernel selected by proxmox-boot-tool.  Respect an
# explicit manual kernel selection; it is an intentional administrator choice.
HOST_KERNEL_REBOOT_REQUIRED () {
  local current_kernel newest_kernel manual_kernels automatic_kernels candidates kernel
  current_kernel=$(uname -r 2>/dev/null || true)
  [[ -n "$current_kernel" ]] || return 1

  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    manual_kernels=$(proxmox-boot-tool kernel list 2>/dev/null | awk '
      /Manually selected kernels:/ {section="manual"; next}
      /Automatically selected kernels:/ {section="automatic"; next}
      section == "manual" && $1 ~ /^[0-9].*-pve$/ {print $1}
    ')
    automatic_kernels=$(proxmox-boot-tool kernel list 2>/dev/null | awk '
      /Manually selected kernels:/ {section="manual"; next}
      /Automatically selected kernels:/ {section="automatic"; next}
      section == "automatic" && $1 ~ /^[0-9].*-pve$/ {print $1}
    ')
    if [[ -n "$manual_kernels" ]]; then
      candidates=$manual_kernels
    else
      candidates=$automatic_kernels
    fi
  else
    candidates=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-pve' -printf '%f\n' 2>/dev/null |
      sed 's/^vmlinuz-//')
  fi

  while IFS= read -r kernel; do
    [[ -n "$kernel" && -e "/boot/vmlinuz-$kernel" ]] || continue
    if [[ -z "$newest_kernel" ]] || dpkg --compare-versions "$kernel" gt "$newest_kernel"; then
      newest_kernel=$kernel
    fi
  done <<< "$candidates"

  [[ -n "$newest_kernel" && "$newest_kernel" != "$current_kernel" ]]
}

## Container ##
# Container Check Start
CONTAINER_CHECK_START () {
  local lifecycle_failure=0 lifecycle_message
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  if ! [[ -d $LOCAL_FILES/temp/ ]]; then mkdir $LOCAL_FILES/temp/; fi
  for CONTAINER in $CONTAINERS; do
    if guest_id_matches "$EXCLUDED" "$CONTAINER"; then
      continue
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$CONTAINER"; then
      continue
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      continue
    else
      if ! STATUS=$(timeout 10 pct status "$CONTAINER" 2>/dev/null); then
        echo -e "${RD}Skipping LXC $CONTAINER because Proxmox did not return its state within 10 seconds${CL}"
        continue
      fi
      if [[ "$STATUS" == "status: stopped" && "${INITIAL_INVENTORY:-false}" == true ]]; then
        STATUS_MODEL_RECORD "$CONTAINER" lxc pct false "" "" "null" "null" not_checked STOPPED_READ_ONLY "LXC $CONTAINER is stopped; initial inventory did not start it" "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED" == true ]]; then
        # Start the container
        pct start "$CONTAINER"
        if WAIT_FOR_BOOTUP_LXC; then
          if ! CHECK_CONTAINER "$CONTAINER"; then
            CHECK_FAILURE=1
          fi
        else
          echo -e "${RD}Skipping LXC $CONTAINER because it did not become reachable${CL}"
        fi
        # Restore the original stopped state and propagate failures instead of
        # presenting a successful check with a changed guest lifecycle.
        if ! pct shutdown "$CONTAINER" --timeout 60 --forceStop 1; then
          lifecycle_failure=1
          lifecycle_message="Could not restore stopped state for LXC $CONTAINER"
          echo -e "${RD}LXC $CONTAINER lifecycle restore failed; check is not successful${CL}"
        elif [[ "$(timeout 10 pct status "$CONTAINER" 2>/dev/null)" != "status: stopped" ]]; then
          lifecycle_failure=1
          lifecycle_message="LXC $CONTAINER did not return to stopped state"
          echo -e "${RD}$lifecycle_message${CL}"
        fi
        if [[ "$lifecycle_failure" -ne 0 ]]; then
          STATUS_MODEL_GUEST_NAME=""
          if declare -f cluster_target_guest_name >/dev/null 2>&1; then
            STATUS_MODEL_GUEST_NAME=$(cluster_target_guest_name "$CONTAINER" 2>/dev/null || true)
          fi
          STATUS_MODEL_RECORD "$CONTAINER" lxc pct true "" "" "null" "null" error LIFECYCLE_RESTORE_FAILED "$lifecycle_message" "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
          CHECK_FAILURE=1
        fi
      elif [[ "$STATUS" == "status: running" && "$RUNNING" == true ]]; then
        if ! CHECK_CONTAINER "$CONTAINER"; then
          CHECK_FAILURE=1
        fi
      fi
    fi
  done
  rm -rf $LOCAL_FILES/temp/temp
}

# Container Check
CHECK_CONTAINER_FAILURE() {
  local message="${1:-LXC check command failed}"
  STATUS_MODEL_RECORD "$CONTAINER" lxc pct true "${OS:-unknown}" "" "null" "null" error CHECK_COMMAND_FAILED "$message"
  CHECK_FAILURE=1
  return 1
}

CHECK_CONTAINER () {
  if [[ "$RDU" != true ]]; then
    CONTAINER=$1
  else
    CONTAINER=$(awk -F'"' '/^CONTAINER=/ {print $2}' $LOCAL_FILES/temp/var)
  fi
  local CONTAINER_UPDATES=0 CONTAINER_STATUS=ok CONTAINER_REBOOT=false pct_config_error
  STATUS_MODEL_GUEST_NAME=""
  if declare -f cluster_target_guest_name >/dev/null 2>&1; then
    STATUS_MODEL_GUEST_NAME=$(cluster_target_guest_name "$CONTAINER" 2>/dev/null || true)
  fi
  if ! mkdir -p -- "$LOCAL_FILES/temp"; then
    CHECK_CONTAINER_FAILURE "Could not initialize temporary LXC check directory for $CONTAINER"
    return
  fi
  if ! pct config "$CONTAINER" > "$LOCAL_FILES/temp/temp" 2>"$LOCAL_FILES/temp/pct-config.error"; then
    pct_config_error=$(tr '\n' ' ' < "$LOCAL_FILES/temp/pct-config.error" 2>/dev/null | sed 's/[[:space:]]\+/ /g' | cut -c1-300)
    CHECK_CONTAINER_FAILURE "Could not read configuration for LXC $CONTAINER${pct_config_error:+: $pct_config_error}"
    return
  fi
  OS=$(awk '/^ostype/' $LOCAL_FILES/temp/temp | cut -d' ' -f2)
  if ! NAME=$(RUN_PCT_COMMAND "$CONTAINER" hostname); then
    CHECK_CONTAINER_FAILURE "Could not read hostname for LXC $CONTAINER"
    return
  fi
  if [[ "${INITIAL_INVENTORY:-false}" == true ]] &&
    ! GUEST_INTERNET_PREFLIGHT_PCT "$CONTAINER"; then
    STATUS_MODEL_RECORD "$CONTAINER" lxc pct false "$OS" "" "null" "null" \
      not_checked NETWORK_UNAVAILABLE \
      "LXC $CONTAINER has no guest internet access; package check skipped" \
      "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
    return 0
  fi
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    if ! RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get update" >/dev/null 2>&1; then
      CHECK_CONTAINER_FAILURE "apt-get update failed for LXC $CONTAINER"
      return
    fi
    if ! APT_OUTPUT=$(RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get -s upgrade"); then
      CHECK_CONTAINER_FAILURE "apt-get -s upgrade failed for LXC $CONTAINER"
      return
    fi
    READ_APT_UPDATE_COUNTS "$APT_OUTPUT"
    if [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
    CONTAINER_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
    if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
    fi
    if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" != 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
    elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / "
    elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
      echo -e "N: $NORMAL_APT_UPDATES"
    fi
  elif [[ "$OS" =~ fedora ]]; then
    if ! UPDATES=$(RUN_PCT_COMMAND "$CONTAINER" bash -c "dnf check-update | grep -Ec ' updates$'"); then
      CHECK_CONTAINER_FAILURE "dnf check-update failed for LXC $CONTAINER"
      return
    fi
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ archlinux ]]; then
    if ! UPDATES=$(RUN_PCT_COMMAND "$CONTAINER" bash -c "pacman -Qu | wc -l"); then
      CHECK_CONTAINER_FAILURE "pacman query failed for LXC $CONTAINER"
      return
    fi
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ alpine ]]; then
    if ! RUN_PCT_COMMAND "$CONTAINER" ash -c "apk update" >/dev/null 2>&1; then
      CHECK_CONTAINER_FAILURE "apk update failed for LXC $CONTAINER"
      return
    fi
    if ! UPDATES=$(RUN_PCT_COMMAND "$CONTAINER" ash -c "apk list -u | wc -l"); then
      CHECK_CONTAINER_FAILURE "apk query failed for LXC $CONTAINER"
      return
    fi
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  else
    if ! UPDATES=$(RUN_PCT_COMMAND "$CONTAINER" bash -c "yum -q check-update | wc -l"); then
      CHECK_CONTAINER_FAILURE "yum check-update failed for LXC $CONTAINER"
      return
    fi
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  fi
  [[ "$CONTAINER_UPDATES" -gt 0 ]] && CONTAINER_STATUS=updates_available
  STATUS_MODEL_RECORD "$CONTAINER" lxc pct true "$OS" "${OS,,}" "$CONTAINER_UPDATES" "$CONTAINER_REBOOT" "$CONTAINER_STATUS" "" ""
}

## VM ##
# VM Check Start
VM_CHECK_START () {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through VMs
  for VM in $VMS; do
    local vm_has_internal_ssh=false
    if declare -f INTERNAL_SSH_HAS_OVERRIDE >/dev/null 2>&1 &&
      INTERNAL_SSH_HAS_OVERRIDE vm "$VM"; then
      vm_has_internal_ssh=true
    fi
    STATUS_MODEL_GUEST_NAME=""
    if declare -f cluster_target_guest_name >/dev/null 2>&1; then
      STATUS_MODEL_GUEST_NAME=$(cluster_target_guest_name "$VM" 2>/dev/null || true)
    fi
    REBOOT_REQUIRED=false
    SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "${VM_START_DELAY:-45}")
    SSH_START_DELAY_TIME=${SSH_START_DELAY_TIME:-45}
    # Check if connection is available
    if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 ]] ||
      [[ -f $LOCAL_FILES/VMs/"$VM" ]] || [[ "$vm_has_internal_ssh" == true ]]; then
      # Check VM
      PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
      if guest_id_matches "$EXCLUDED" "$VM"; then
        continue
      elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$VM"; then
        continue
      elif [[ "$PRE_OS" =~ w ]]; then
        continue
      else
        STATUS=$(qm status "$VM")
        if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
          IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          USER="${USER:-root}"
          SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          SSH_VM_PORT="${SSH_VM_PORT:-22}"
          SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "$SSH_START_DELAY_TIME")
          SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-$VM_START_DELAY}"
        fi
        if [[ "$STATUS" == "status: stopped" && "${INITIAL_INVENTORY:-false}" == true ]]; then
          STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" not_checked STOPPED_READ_ONLY "VM $VM is stopped; initial inventory did not start it" "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
        elif [[ "$STATUS" == "status: paused" && "${INITIAL_INVENTORY:-false}" == true ]]; then
          STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" not_checked PAUSED_READ_ONLY "VM $VM is paused; initial inventory did not resume it" "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
        elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
          # Check suspend mode
          if [[ $(qm config "$VM" | grep 'lock:' | sed 's/lock:\s*//') == "suspend" ]]; then 
            SUSPEND=true
            echo -e "${OR}skip suspend VM${CL}"
            continue
          fi
          # Start VM
          qm start "$VM" >/dev/null 2>&1
          if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
            sleep "$SSH_START_DELAY_TIME"
            CHECK_VM "$VM"
          elif WAIT_FOR_QGA; then
            CHECK_VM "$VM"
          else
            echo -e "${RD}Skipping VM $VM because QEMU Guest Agent is not ready${CL}"
            STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" offline QGA_NOT_READY "QEMU Guest Agent was not ready"
          fi
          # Stop/Suspend VM
          qm stop "$VM"
          SUSPEND=
        elif [[ "$STATUS" == "status: paused" && "$PAUSED_VM" == true ]]; then
          # Start VM
          qm resume "$VM" >/dev/null 2>&1
          sleep "$SSH_START_DELAY_TIME"
          CHECK_VM "$VM"
          # Suspend VM
          qm suspend "$VM"
        elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
          VM_NOT_STOPPED=true
          CHECK_VM "$VM"
          VM_NOT_STOPPED=""
        fi
      fi
    fi
  done
}

# VM Check
CHECK_VM () {
  local IP USER SSH_VM_PORT SSH_START_DELAY_TIME ssh_profile_configured=false ssh_error
  REBOOT_REQUIRED=false
  if [[ "$RDU" != true ]]; then
    VM=$1
  else
    VM=$(awk -F'"' '/^VM=/ {print $2}' $LOCAL_FILES/temp/var)
  fi
  STATUS_MODEL_GUEST_NAME=""
  if declare -f cluster_target_guest_name >/dev/null 2>&1; then
    STATUS_MODEL_GUEST_NAME=$(cluster_target_guest_name "$VM" 2>/dev/null || true)
  fi
  if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
    ssh_profile_configured=true
    IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "$SSH_START_DELAY_TIME")
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-$VM_START_DELAY}"
  fi
  if declare -f INTERNAL_SSH_HAS_OVERRIDE >/dev/null 2>&1 &&
    INTERNAL_SSH_HAS_OVERRIDE vm "$VM"; then
    ssh_profile_configured=true
  fi
  INTERNAL_SSH_RESOLVE_VM "$VM" "${IP:-}" "${USER:-root}" "${SSH_VM_PORT:-22}" || return 1
  [[ "${INTERNAL_SSH_ENABLED:-true}" == true ]] || return 1
  IP="${INTERNAL_SSH_HOST:-$IP}"; USER="${INTERNAL_SSH_USER:-$USER}"; SSH_VM_PORT="${INTERNAL_SSH_PORT:-$SSH_VM_PORT}"
  INTERNAL_SSH_USE_IDENTITY
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  if [[ -z "$IP" || -z "$USER" || -z "$SSH_VM_PORT" ]]; then
    CHECK_VM_QEMU
    return
  fi
  if ! ssh_error=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "true" 2>&1); then
    ssh_error=$(printf '%s' "$ssh_error" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-300)
    if [[ "$ssh_profile_configured" == true ]]; then
      STATUS_MODEL_RECORD "$VM" vm ssh false "" "" "null" "null" error SSH_TRANSPORT \
        "Internal SSH connection failed for VM $VM${ssh_error:+: $ssh_error}" \
        "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
      return 1
    fi
    CHECK_VM_QEMU
    return
  fi
  if [[ "${INITIAL_INVENTORY:-false}" == true ]] &&
    ! GUEST_INTERNET_PREFLIGHT_SSH "$IP" "$SSH_VM_PORT" "$USER"; then
    STATUS_MODEL_RECORD "$VM" vm ssh false "" "" "null" "null" \
      not_checked NETWORK_UNAVAILABLE \
      "VM $VM has no guest internet access; package check skipped" \
      "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
    return 0
  fi
  OS_BASE=$(qm config "$VM" | grep ostype || true)
  if [[ "$OS_BASE" =~ l2 ]]; then
    KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
    OS=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" hostnamectl 2>/dev/null | grep System || true)
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apt-get update" >/dev/null 2>&1
      APT_OUTPUT=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apt-get -s upgrade")
      READ_APT_UPDATE_COUNTS "$APT_OUTPUT"
      if RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" stat /var/run/reboot-required.pkgs >/dev/null 2>&1; then
        REBOOT_REQUIRED=true
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${OR} Reboot required${CL}"
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
      elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / "
      elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "N: $NORMAL_APT_UPDATES"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]] && [[ "$REBOOT_IF_NEEDED" == true ]] && [[ "$VM_NOT_STOPPED" == true ]]; then
        RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "reboot" >/dev/null 2>&1
      fi
    elif [[ "$OS" =~ Fedora ]]; then
      UPDATES=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "dnf check-update | grep -Ec ' updates$'")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Arch ]]; then
      UPDATES=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "pacman -Qu | wc -l")
      UPDATES=${UPDATES//[^0-9]/}
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Alpine ]]; then
      UPDATES=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apk list -u | wc -l")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ CentOS ]]; then
      UPDATES=$(RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "yum -q check-update | wc -l")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    fi
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      SSH_MODEL_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
      SSH_MODEL_STATUS=ok
      [[ "$SSH_MODEL_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && SSH_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" apt "$SSH_MODEL_UPDATES" "${REBOOT_REQUIRED:-false}" "$SSH_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ fedora ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" dnf "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ arch ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" pacman "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ alpine ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" apk "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ centos ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" yum "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    else
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" "" "null" "null" unsupported UNSUPPORTED_OS "No supported updater detected"
    fi
  fi
}

CHECK_VM_QEMU () {
  local OS_INFO OS_NAME OS_NAME_LOWER
  # A successful agent ping proves QGA transport without assuming that the
  # guest contains a Linux executable such as /bin/true.  FreeBSD/pfSense
  # commonly has a working agent but no Linux guest-exec environment.
  if ! timeout 10 qm agent "$VM" ping >/dev/null 2>&1; then
    STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" error QGA_TRANSPORT "QEMU Guest Agent ping failed"
    return 1
  fi
  OS_INFO=$(qm guest cmd "$VM" get-osinfo 2>/dev/null || true)
  OS=$(printf '%s\n' "$OS_INFO" | grep name || true)
  OS_NAME=${OS#*:}
  OS_NAME="${OS_NAME#"${OS_NAME%%[![:space:]]*}"}"
  OS_NAME="${OS_NAME//\"/}"
  OS_NAME="${OS_NAME//\'/}"
  OS_NAME_LOWER="${OS_NAME,,}"
  if [[ "${OS_INFO,,}" =~ windows ]]; then
    CHECK_VM_QEMU_WINDOWS
    return
  fi
  if [[ "$OS_NAME_LOWER" =~ freebsd|pfsense ]]; then
    if [[ "${INITIAL_INVENTORY:-false}" == true ]]; then
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS_NAME" "" "null" "null" \
        not_checked UNSUPPORTED_GUEST_OS \
        "QEMU Guest Agent is reachable, but FreeBSD/pfSense package checks are not supported" \
        "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
      return 0
    fi
    STATUS_MODEL_RECORD "$VM" vm qga true "$OS_NAME" "" "null" "null" unsupported UNSUPPORTED_GUEST_OS "No supported updater detected"
    return 0
  fi
  # Do not guess a Linux guest from a successful QGA ping alone.  In the
  # read-only onboarding mode an unknown OS must not trigger a Linux-specific
  # guest-exec probe and turn a reachable agent into a false transport error.
  if [[ "${INITIAL_INVENTORY:-false}" == true && -z "$OS_NAME_LOWER" ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga true "" "" "null" "null" \
      not_checked UNSUPPORTED_GUEST_OS \
      "QEMU Guest Agent is reachable, but the guest OS could not be identified" \
      "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
    return 0
  fi
  # Use an explicit successful command for the QGA readiness probe.  The
  # shell builtin/executable `test` without arguments intentionally exits 1,
  # which must not be mistaken for a guest-agent transport failure.
  QEMU_GUEST_EXEC "$VM" --timeout 30 -- /bin/true
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" error QGA_TRANSPORT "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  if [[ "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga true "" "" "null" "null" error QGA_GUEST_EXEC "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]; then
    if [[ "${INITIAL_INVENTORY:-false}" == true ]] &&
      ! GUEST_INTERNET_PREFLIGHT_QGA "$VM"; then
      STATUS_MODEL_RECORD "$VM" vm qga false "$OS" "" "null" "null" \
        not_checked NETWORK_UNAVAILABLE \
        "VM $VM has no guest internet access; package check skipped" \
        "${STATUS_MODEL_NODE:-$HOSTNAME}" "$STATUS_MODEL_GUEST_NAME"
      return 0
    fi
    KERNEL=$(printf '%s\n' "$OS_INFO" | grep kernel-version || true)
#    if [[ "$KERNEL" =~ FreeBSD ]]; then
#      qm guest exec "$VM" -- tcsh -c "pkg update"
#      return
#    fi
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "apt-get update"
      if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
        echo -e "${RD}QEMU apt update failed for VM $VM: ${QEMU_EXEC_OUTPUT}${CL}"
        return 1
      fi
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "apt-get -s upgrade | grep -ci '^inst.*security'"
      QEMU_COUNT_RESULT_OK "QEMU security update check for VM $VM" || return 1
      SECURITY_APT_UPDATES="$QEMU_EXEC_STDOUT"
      SECURITY_APT_UPDATES=$(SANITIZE_NUMBER "$SECURITY_APT_UPDATES")
      SECURITY_APT_UPDATES=${SECURITY_APT_UPDATES:-0}
      if [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "apt-get -s upgrade | grep -ci '^inst.'"
      QEMU_COUNT_RESULT_OK "QEMU update check for VM $VM" || return 1
      NORMAL_APT_UPDATES="$QEMU_EXEC_STDOUT"
      NORMAL_APT_UPDATES=$(SANITIZE_NUMBER "$NORMAL_APT_UPDATES")
      NORMAL_APT_UPDATES=${NORMAL_APT_UPDATES:-0}
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c '[ -f /var/run/reboot-required.pkgs ]'
      if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
        echo -e "${RD}QEMU reboot check failed for VM $VM: ${QEMU_EXEC_OUTPUT}${CL}"
        return 1
      fi
      EXITCODE=$QEMU_EXEC_EXITCODE
      EXITCODE=${EXITCODE:-1}
      if [[ "$EXITCODE" -eq 0 ]]; then
        REBOOT_REQUIRED=true
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]]; then echo -e "${OR} Reboot required${CL}"; fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
      elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / "
      elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "N: $NORMAL_APT_UPDATES"
      fi
      QEMU_APT_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
      QEMU_APT_STATUS=ok
      [[ "$QEMU_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && QEMU_APT_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" apt "$QEMU_APT_UPDATES" "$REBOOT_REQUIRED" "$QEMU_APT_STATUS" "" ""
    elif [[ "$OS" =~ Fedora ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "dnf check-update | grep -Ec ' updates$'"
      QEMU_COUNT_RESULT_OK "QEMU dnf check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_DNF_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_DNF_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" dnf "$UPDATES" false "$QEMU_DNF_STATUS" "" ""
    elif [[ "$OS" =~ Arch ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "pacman -Qu | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU pacman check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_PACMAN_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_PACMAN_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" pacman "$UPDATES" false "$QEMU_PACMAN_STATUS" "" ""
    elif [[ "$OS" =~ Alpine ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- ash -c "apk list -u | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU apk check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_APK_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_APK_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" apk "$UPDATES" false "$QEMU_APK_STATUS" "" ""
    elif [[ "$OS" =~ CentOS ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 120 -- bash -c "yum -q check-update | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU yum check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_YUM_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_YUM_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" yum "$UPDATES" false "$QEMU_YUM_STATUS" "" ""
    else
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" "" "null" "null" unsupported UNSUPPORTED_OS "No supported updater detected"
    fi
  fi
}

CHECK_VM_QEMU_WINDOWS () {
  local result marker check_status updates reboot message windows_os reachable=true error_code=WINDOWS_UPDATE_CHECK
  windows_os=$(printf '%s\n' "$OS" | sed -E 's/^[[:space:]]*name[[:space:]]*:[[:space:]]*//')
  windows_os="${windows_os:-Windows}"
  if ! declare -f WINDOWS_POWERSHELL_ENCODE >/dev/null 2>&1; then
    STATUS_MODEL_RECORD "$VM" vm qga true "$windows_os" windows-update "null" "null" error WINDOWS_HELPER_MISSING "Windows update helper is not installed"
    return 1
  fi
  QEMU_GUEST_EXEC "$VM" --timeout 120 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$(WINDOWS_POWERSHELL_ENCODE check)"
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    reachable=false
    error_code=QGA_TRANSPORT
    STATUS_MODEL_RECORD "$VM" vm qga "$reachable" "$windows_os" windows-update "null" "null" error "$error_code" "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  if [[ "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    if grep -Eqi 'disabled|not allowed|not permitted|permission denied' <<< "$QEMU_EXEC_OUTPUT"; then
      error_code=QGA_GUEST_EXEC_DISABLED
    fi
    STATUS_MODEL_RECORD "$VM" vm qga "$reachable" "$windows_os" windows-update "null" "null" error "$error_code" "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" | tr -d '\r' | tail -n 1)
  IFS='|' read -r marker check_status updates reboot message <<< "$result"
  if [[ "$marker" != UU_WINDOWS || "$check_status" != ok || ! "$updates" =~ ^[0-9]+$ || ("$reboot" != true && "$reboot" != false) ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga true "$windows_os" windows-update "null" "null" error WINDOWS_UPDATE_CHECK "Invalid Windows Update response: $result"
    return 1
  fi
  STATUS_MODEL_STATUS=ok
  [[ "$updates" -gt 0 || "$reboot" == true ]] && STATUS_MODEL_STATUS=updates_available
  STATUS_MODEL_RECORD "$VM" vm qga true "$windows_os" windows-update "$updates" "$reboot" "$STATUS_MODEL_STATUS" "" ""
  if [[ "$updates" -gt 0 || "$reboot" == true ]]; then
    echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
    echo -e "Windows updates: $updates"
  fi
  [[ "$reboot" == true ]] && echo -e "${OR} Reboot required${CL}"
}

# Output to file
OUTPUT_TO_FILE () {
  if [[ "$RDU" != true && "$RICM" != true ]]; then
    touch $LOCAL_FILES/check-output
    exec > >(tee $LOCAL_FILES/check-output)
    touch $LOCAL_FILES/mail-output
  fi
}

# Exit
# shellcheck disable=SC2329
EXIT () {
  # Create the mail output from the completed check output.
  if [[ "$RDU" != true && "$RICM" != true && "${UU_DEFER_NOTIFICATION:-false}" != true ]]; then
    # Close the tee input before waiting for its final writes.
    exec 1>/dev/null
    wait
    if [[ -f "$LOCAL_FILES/check-output" ]]; then
      local status_notification_sent=false
      if declare -f STATUS_MODEL_SEND_NOTIFICATION >/dev/null 2>&1 &&
        STATUS_MODEL_SEND_NOTIFICATION "$LOCAL_FILES/status.json" "$CONFIG_FILE"; then
        status_notification_sent=true
      fi
      if [[ "$status_notification_sent" != true ]]; then
        {
          echo -e "Available Updates:"
          echo -e "S = Security / N = Normal\n"
          sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" "$LOCAL_FILES/check-output"
        } > "$LOCAL_FILES/mail-output"
        chmod 640 "$LOCAL_FILES/mail-output"
        if [[ $(stat -c%s "$LOCAL_FILES/mail-output") -gt 46 ]]; then
          # check variable !!!
          if [[ "$EMAIL_ONLY_SECURITY" == true && "$SECURITY_UPDATES_AVALABLE" == true ]]; then
            mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" < "$LOCAL_FILES"/mail-output
          else
            mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" < "$LOCAL_FILES"/mail-output
          fi
        elif [[ "$EMAIL_NO_UPDATES" == true ]]; then
          echo "No updates found during search" | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater" "$EMAIL_USER"
        fi
      fi
    fi
  fi
  if [[ "${UU_REMOTE_DEFER_STATUS_FINISH:-false}" != true ]] &&
    declare -f STATUS_MODEL_CLEANUP >/dev/null 2>&1; then
    STATUS_MODEL_CLEANUP
  fi
}
trap EXIT EXIT

# Run

# Debug
DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' $CONFIG_FILE)
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Check Cluster Mode
if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster"
else
  MODE="Host"
fi

# Read config
READ_WRITE_CONFIG
STATUS_MODEL_ENABLED=false
status_model_init_rc=0
if STATUS_MODEL_INIT; then
  STATUS_MODEL_ENABLED=true
else
  status_model_init_rc=$?
  CHECK_FAILURE=1
fi
STATUS_MODEL_DIAGNOSTIC "STATUS_MODEL_INIT node=${STATUS_MODEL_NODE:-${HOSTNAME:-unknown}} script=${STATUS_MODEL_SCRIPT:-unknown} file=${STATUS_MODEL_FILE:-unknown} records=${STATUS_MODEL_RECORD_FILE:-unknown} enabled=$STATUS_MODEL_ENABLED rc=$status_model_init_rc"
if [[ -n "${UU_JOB_SOURCE:-}" ]]; then
  STATUS_MODEL_DIAGNOSTIC "REMOTE_JOB_SOURCE=${UU_JOB_SOURCE} REMOTE_INITIAL_INVENTORY=$INITIAL_INVENTORY"
fi
if wget -q --spider "$CHECK_URL" >/dev/null 2>&1; then
  ARGUMENTS "$@"
  # Print any tag selection summary captured during config parse
  if [[ "$RDU" != true && "$RICM" != true && "$TAG_OUTPUT" != false ]]; then if declare -f print_tag_log >/dev/null 2>&1; then print_tag_log; fi; fi
else
  echo -e "${OR} You are offline${CL}"
  exit 2
fi

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true && "$RDU" == true ]]; then
  OUTPUT_TO_FILE
elif [[ "$COMMAND" != true ]]; then
  OUTPUT_TO_FILE
  if [[ "$MODE" =~ Cluster ]]; then HOST_CHECK_START; else
    if [[ "$WITH_HOST" == true ]]; then CHECK_HOST_ITSELF; fi
    if [[ "$WITH_LXC" == true ]]; then CONTAINER_CHECK_START; fi
    if [[ "$WITH_VM" == true ]]; then VM_CHECK_START; fi
  fi
fi

# Refresh the local MOTD version cache without making the login path depend on GitHub.
UPDATE_VERSION_CACHE >/dev/null 2>&1 || true
if [[ "$STATUS_MODEL_ENABLED" == true && "${UU_REMOTE_DEFER_STATUS_FINISH:-false}" != true ]]; then
  if declare -f STATUS_MODEL_HAS_FAILURES >/dev/null 2>&1 && STATUS_MODEL_HAS_FAILURES; then
    CHECK_FAILURE=1
  fi
  status_finish_rc=0
  status_finish_error_file="${STATUS_MODEL_DIAGNOSTICS_FILE:-$LOCAL_FILES/.status-model-diagnostics.$$}.finish-error"
  STATUS_MODEL_FINISH >/dev/null 2>"$status_finish_error_file" || status_finish_rc=$?
  if [[ "$status_finish_rc" -ne 0 ]]; then
    CHECK_FAILURE=1
  fi
  status_finish_reason=none
  if [[ -s "$status_finish_error_file" ]]; then
    status_finish_reason=$(tr '\n' ' ' < "$status_finish_error_file" | cut -c1-500)
  fi
  status_finish_exists=false
  [[ -s "${STATUS_MODEL_FILE:-}" ]] && status_finish_exists=true
  status_finish_size=0
  if [[ "$status_finish_exists" == true ]]; then
    status_finish_size=$(stat -c '%s' "$STATUS_MODEL_FILE" 2>/dev/null || printf '0')
  fi
  STATUS_MODEL_DIAGNOSTIC "STATUS_MODEL_FINISH node=${STATUS_MODEL_NODE:-${HOSTNAME:-unknown}} file=${STATUS_MODEL_FILE:-unknown} records=${STATUS_MODEL_RECORD_FILE:-unknown} rc=$status_finish_rc exists=$status_finish_exists size=$status_finish_size reason=$status_finish_reason"
  rm -f -- "$status_finish_error_file"
fi

exit "$CHECK_FAILURE"
