#!/bin/bash
# shellcheck disable=SC2034 # shared runtime globals are consumed by sourced callers

# Small shared runtime helpers for the Target -> Transport -> Updater split.
# These wrappers only select an existing transport; they do not add retries,
# lifecycle handling, authentication, or update policy.

# Return success when the Proxmox VM configuration enables the QEMU Guest
# Agent.  Proxmox supports both the legacy shorthand (`agent: 1`) and the
# property form (`agent: enabled=1`), with optional comma-separated settings.
# This intentionally checks configuration only; runtime readiness is still
# established by the existing qm agent/guest-exec probes.
QGA_CONFIG_ENABLED() {
  local vmid="${1:-}" agent_value primary
  [[ "$vmid" =~ ^[0-9]+$ ]] || return 1
  agent_value=$(qm config "$vmid" 2>/dev/null |
    awk -F: '$1 ~ /^[[:space:]]*agent[[:space:]]*$/ {
      value=$2
      sub(/^[[:space:]]*/, "", value)
      print value
      exit
    }') || return 1
  primary=${agent_value%%,*}
  case "$primary" in
    1|enabled=1) return 0 ;;
    *) return 1 ;;
  esac
}

RUN_LOCAL_COMMAND() {
  "$@"
}

RUN_PCT_COMMAND() {
  local target_id="$1"
  shift
  timeout "${UU_CHECK_PCT_COMMAND_TIMEOUT:-120}" pct exec "$target_id" -- "$@"
}

RUN_SSH_COMMAND() {
  local host="$1" port="$2" user="$3"
  shift 3
  local identity_file="${RUN_SSH_IDENTITY_FILE:-}"
  local -a ssh_options=(-q -o BatchMode=yes -o ConnectTimeout=5)
  if [[ -n "$identity_file" ]]; then
    ssh_options+=(-o IdentitiesOnly=yes -i "$identity_file")
  fi
  timeout "${UU_SSH_COMMAND_TIMEOUT:-120}" ssh "${ssh_options[@]}" -p "$port" "$user@$host" "$@"
}

# Execute a mutating update step exactly once while keeping its combined
# stdout/stderr available to both the user and the updater error model.
RUN_CAPTURED_COMMAND() {
  local output_file command_rc tee_rc had_errexit=false command_text
  local -a pipeline_status

  COMMAND_CAPTURE_OUTPUT=""
  COMMAND_CAPTURE_STATUS=1

  output_file=$(mktemp "${TMPDIR:-/tmp}/ultimate-updater-step.XXXXXX") || {
    COMMAND_CAPTURE_OUTPUT="Unable to create temporary output file for update step."
    COMMAND_CAPTURE_STATUS=1
    return 1
  }

  if [[ $- == *e* ]]; then
    had_errexit=true
    set +e
  fi

  "$@" 2>&1 | tee "$output_file"
  pipeline_status=("${PIPESTATUS[@]}")

  if [[ "$had_errexit" == true ]]; then
    set -e
  fi

  command_rc=${pipeline_status[0]:-1}
  tee_rc=${pipeline_status[1]:-0}
  if (( command_rc == 0 && tee_rc != 0 )); then
    command_rc=$tee_rc
  fi

  COMMAND_CAPTURE_OUTPUT=$(<"$output_file")
  rm -f -- "$output_file"

  COMMAND_CAPTURE_STATUS=$command_rc
  if (( command_rc != 0 && ${#COMMAND_CAPTURE_OUTPUT} == 0 )); then
    printf -v command_text '%q ' "$@"
    COMMAND_CAPTURE_OUTPUT="Command failed without output: ${command_text% }"
  fi

  return "$command_rc"
}

RUN_UPDATE_STEP() {
  local target_id="$1" target_name="$2" rc
  shift 2

  if RUN_CAPTURED_COMMAND "$@"; then
    return 0
  else
    rc=$?
  fi

  ERROR_CODE=$rc
  ID="$target_id"
  NAME="$target_name"
  ERROR_MSG="$COMMAND_CAPTURE_OUTPUT"
  if declare -F ERROR >/dev/null 2>&1; then
    ERROR
  else
    printf '%s\n' "$ERROR_MSG" >&2
  fi
  return "$rc"
}

RUN_HOST_STEP() {
  RUN_UPDATE_STEP "${HOSTNAME:-HOST}" "${HOSTNAME:-HOST}" "$@"
}

RUN_LXC_STEP() {
  RUN_UPDATE_STEP "${CONTAINER:-LXC}" "${NAME:-LXC ${CONTAINER:-unknown}}" "$@"
}

RUN_VM_SSH_STEP() {
  RUN_UPDATE_STEP "${VM:-VM}" "${NAME:-VM ${VM:-unknown}}" "$@"
}

READ_APT_UPDATE_COUNTS() {
  local script="${APT_COUNT_SCRIPT:-${LOCAL_FILES:-/etc/ultimate-updater}/apt-count.py}"
  local result
  result=$(python3 "$script") || {
    SECURITY_APT_UPDATES=null
    NORMAL_APT_UPDATES=null
    APT_COUNTS_TOTAL=null
    return 1
  }
  PARSE_APT_UPDATE_COUNTS "$result"
}

PARSE_APT_UPDATE_COUNTS() {
  local result="$1" total normal security known
  IFS='|' read -r _ total normal security known _ <<<"$result"
  if [[ ! "$total" =~ ^[0-9]+$ || ! "$normal" =~ ^[0-9]+$ ||
    ! "$security" =~ ^[0-9]+$ || "$known" != true ]]; then
    SECURITY_APT_UPDATES=null
    NORMAL_APT_UPDATES=null
    APT_COUNTS_TOTAL=null
    return 1
  fi
  # shellcheck disable=SC2034
  APT_COUNTS_TOTAL="$total"
  # shellcheck disable=SC2034
  NORMAL_APT_UPDATES="$normal"
  # shellcheck disable=SC2034
  SECURITY_APT_UPDATES="$security"
  [[ $((normal + security)) -eq $total ]]
}

APT_COUNT_REMOTE_COMMAND() {
  local script="${APT_COUNT_SCRIPT:-${LOCAL_FILES:-/etc/ultimate-updater}/apt-count.py}"
  local encoded
  encoded=$(base64 -w0 "$script") || return 1
  printf 'python3 -c %q' "import base64;exec(base64.b64decode('$encoded'))"
}

READ_RPM_UPDATE_COUNTS() {
  local script="${RPM_COUNT_SCRIPT:-${LOCAL_FILES:-/etc/ultimate-updater}/rpm-count.py}"
  local result
  result=$(python3 "$script") || {
    RPM_COUNTS_TOTAL=null
    RPM_SECURITY_UPDATES=null
    RPM_NORMAL_UPDATES=null
    return 1
  }
  PARSE_RPM_UPDATE_COUNTS "$result"
}

PARSE_RPM_UPDATE_COUNTS() {
  local result="$1" marker status total normal security known
  IFS='|' read -r marker status total normal security known _ <<<"$result"
  if [[ "$marker" != UU_RPM_COUNTS || "$status" != ok ||
    ! "$total" =~ ^[0-9]+$ || "$normal" != null || "$security" != null ||
    "$known" != false ]]; then
    RPM_COUNTS_TOTAL=null
    RPM_SECURITY_UPDATES=null
    RPM_NORMAL_UPDATES=null
    return 1
  fi
  # shellcheck disable=SC2034
  RPM_COUNTS_TOTAL="$total"
  # shellcheck disable=SC2034
  RPM_SECURITY_UPDATES=null
  # shellcheck disable=SC2034
  RPM_NORMAL_UPDATES=null
}

RPM_COUNT_REMOTE_COMMAND() {
  local script="${RPM_COUNT_SCRIPT:-${LOCAL_FILES:-/etc/ultimate-updater}/rpm-count.py}"
  local encoded
  encoded=$(base64 -w0 "$script") || return 1
  printf 'python3 -c %q' "import base64;exec(base64.b64decode('$encoded'))"
}

PARSE_PACKAGE_UPDATE_COUNTS() {
  local result="$1" marker status manager total normal security known
  IFS='|' read -r marker status manager total normal security known _ <<<"$result"
  if [[ "$marker" != UU_PACKAGE_COUNTS || "$status" != ok ||
    ! "$total" =~ ^[0-9]+$ || "$normal" != null || "$security" != null ||
    "$known" != false ]]; then
    PACKAGE_COUNTS_TOTAL=null
    PACKAGE_NORMAL_UPDATES=null
    PACKAGE_SECURITY_UPDATES=null
    return 1
  fi
  # shellcheck disable=SC2034
  PACKAGE_COUNTS_TOTAL="$total"
  # shellcheck disable=SC2034
  PACKAGE_NORMAL_UPDATES=null
  # shellcheck disable=SC2034
  PACKAGE_SECURITY_UPDATES=null
}

PACKAGE_COUNT_REMOTE_COMMAND() {
  local manager="$1" script="${PACKAGE_COUNT_SCRIPT:-${LOCAL_FILES:-/etc/ultimate-updater}/package-count.sh}"
  local encoded
  encoded=$(base64 -w0 "$script") || return 1
  printf 'printf %%s %q | base64 -d | sh -s -- %q' "$encoded" "$manager"
}

CLASSIFY_SSH_EXIT() {
  case "$1" in
    0) printf 'SSH_OK' ;;
    124) printf 'SSH_TIMEOUT' ;;
    255) printf 'SSH_CONNECTION_FAILED' ;;
    *) printf 'REMOTE_COMMAND_FAILED' ;;
  esac
}

# Proxmox commands are noisy because the API prints task/UPID progress. Keep
# that implementation detail out of normal user logs while retaining the
# exact command output and return code for DEBUG and caller-side diagnostics.
RUN_PROXMOX_COMMAND() {
  if [[ "${DEBUG:-false}" == true ]]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

RUN_PROXMOX_CAPTURE() {
  local rc
  PROXMOX_CAPTURE_OUTPUT=$("$@" 2>&1)
  rc=$?
  if [[ "${DEBUG:-false}" == true && -n "$PROXMOX_CAPTURE_OUTPUT" ]]; then
    printf '%s\n' "$PROXMOX_CAPTURE_OUTPUT"
  fi
  return "$rc"
}
