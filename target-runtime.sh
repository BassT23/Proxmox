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
  pct exec "$target_id" -- "$@"
}

RUN_SSH_COMMAND() {
  local host="$1" port="$2" user="$3"
  shift 3
  ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"
}

READ_APT_UPDATE_COUNTS() {
  local apt_output="$1"
  # shellcheck disable=SC2034
  SECURITY_APT_UPDATES=$(printf '%s\n' "$apt_output" | grep -ci '^inst.*security' || true)
  # shellcheck disable=SC2034
  NORMAL_APT_UPDATES=$(printf '%s\n' "$apt_output" | grep -ci '^inst.' || true)
}
