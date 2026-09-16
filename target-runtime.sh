#!/bin/bash

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
