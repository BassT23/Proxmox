#!/bin/bash

# Central management transport for the target-local External configuration.
# The remote path and action are fixed; values are validated before transport.

set -o pipefail

LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INVENTORY_SCRIPT="$LOCAL_FILES/target-inventory.sh"
RUNTIME_SCRIPT="$LOCAL_FILES/target-runtime.sh"
CONFIG_PATH=/etc/ultimate-updater/external.conf
HELPER_PATH=/usr/local/sbin/ultimate-updater-external
[[ -f "$INVENTORY_SCRIPT" ]] || INVENTORY_SCRIPT="$SCRIPT_DIR/target-inventory.sh"
[[ -f "$RUNTIME_SCRIPT" ]] || RUNTIME_SCRIPT="$SCRIPT_DIR/target-runtime.sh"
# shellcheck disable=SC1090
source "$INVENTORY_SCRIPT"
# shellcheck disable=SC1090
source "$RUNTIME_SCRIPT"
# shellcheck disable=SC1091
# shellcheck disable=SC1090
source "$SCRIPT_DIR/external-config.sh"

usage() { printf 'Usage: %s get TARGET | set TARGET KEY=VALUE...\n' "$0" >&2; }

load_target() {
  local target="$1" inventory_file="$LOCAL_FILES/targets.conf"
  TARGET_INVENTORY_VALIDATE "$inventory_file" || return 2
  [[ "${TARGET_TRANSPORT[$target]:-}" == ssh ]] || return 3
  EXTERNAL_HOST="${TARGET_HOST[$target]}"
  EXTERNAL_PORT="${TARGET_PORT[$target]:-22}"
  EXTERNAL_USER="${TARGET_USER[$target]:-root}"
  EXTERNAL_IDENTITY_FILE="${TARGET_IDENTITY_FILE[$target]:-}"
  if [[ -n "$EXTERNAL_IDENTITY_FILE" ]]; then
    [[ -r "$EXTERNAL_IDENTITY_FILE" ]] || return 4
  fi
}

remote_command() {
  local identity_args=()
  if [[ -n "$EXTERNAL_IDENTITY_FILE" ]]; then
    identity_args=(-o IdentitiesOnly=yes -i "$EXTERNAL_IDENTITY_FILE")
  fi
  timeout "${UU_SSH_COMMAND_TIMEOUT:-120}" ssh -q -o BatchMode=yes -o ConnectTimeout=5 \
    "${identity_args[@]}" -p "$EXTERNAL_PORT" "$EXTERNAL_USER@$EXTERNAL_HOST" "$@"
}

remote_read() {
  remote_command "/bin/cat -- $CONFIG_PATH"
}

validate_value() {
  local key="$1" value="$2"
  external_config_key_allowed "$key" || return 2
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && ${#value} -le 512 ]] || return 2
}

settings_get() {
  local target="$1" output temporary
  load_target "$target" || { printf 'External target is unavailable or invalid: %s\n' "$target" >&2; return 3; }
  output=$(remote_read) || { printf 'External settings unavailable: target offline or SSH failed\n' >&2; return 10; }
  temporary=$(mktemp "${TMPDIR:-/tmp}/ultimate-updater-external-settings.XXXXXX") || return 1
  printf '%s\n' "$output" > "$temporary"
  if ! external_config_validate "$temporary"; then
    printf 'External settings invalid on target: %s\n' "$target" >&2
    rm -f -- "$temporary"
    return 11
  fi
  printf '%s\n' "$output"
  rm -f -- "$temporary"
}

settings_set() {
  local target="$1" pair key value existing key_value content
  shift
  load_target "$target" || { printf 'External target is unavailable or invalid: %s\n' "$target" >&2; return 3; }
  [[ $# -le 4 ]] || { printf 'Too many External settings\n' >&2; return 2; }
  declare -A requested=()
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || return 2
    key=${pair%%=*}; value=${pair#*=}
    validate_value "$key" "$value" || { printf 'Unsupported or invalid setting: %s\n' "$key" >&2; return 2; }
    requested["$key"]="$value"
  done
  existing=$(settings_get "$target") || return $?
  content='schema_version="1"'
  for key in ONLY_UPDATE_CHECK EXCLUDE_UPDATE_CHECK ONLY EXCLUDE; do
    if [[ ${requested[$key]+yes} == yes ]]; then
      key_value=${requested[$key]}
    else
      key_value=$(printf '%s\n' "$existing" | awk -F= -v wanted="$key" '$1 == wanted {v=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",v); print v; exit}')
    fi
    escaped=$(printf '%s' "$key_value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    content+=$'\n'"$key=\"$escaped\""
  done
  printf '%s\n' "$content" | remote_command "sudo -n $HELPER_PATH config-write" >/dev/null || {
    printf 'External settings write failed: target offline, denied, or rejected\n' >&2
    return 12
  }
  printf 'External settings updated: %s\n' "$target"
}

case "${1:-}" in
  get) [[ $# -eq 2 ]] || { usage; exit 2; }; settings_get "$2" ;;
  set) [[ $# -ge 2 ]] || { usage; exit 2; }; settings_set "$2" "${@:3}" ;;
  *) usage; exit 2 ;;
esac
