#!/bin/bash

# Small shared runtime helpers for the Target -> Transport -> Updater split.
# These wrappers only select an existing transport; they do not add retries,
# lifecycle handling, authentication, or update policy.

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
  local apt_output="$1"
  # shellcheck disable=SC2034
  SECURITY_APT_UPDATES=$(printf '%s\n' "$apt_output" | grep -ci '^inst.*security' || true)
  # shellcheck disable=SC2034
  NORMAL_APT_UPDATES=$(printf '%s\n' "$apt_output" | grep -ci '^inst.' || true)
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
