#!/bin/bash
# shellcheck disable=SC2034,SC2120

# Internal SSH overrides for Proxmox nodes and Proxmox guests.
# This is deliberately separate from targets.conf: the latter is only the
# inventory of External Targets.  Values are parsed as data, never sourced.

INTERNAL_SSH_CONFIG_FILE="${INTERNAL_SSH_CONFIG_FILE:-${LOCAL_FILES:-/etc/ultimate-updater}/internal-ssh.conf}"
INTERNAL_SSH_ERROR=""
INTERNAL_SSH_IDENTITY_FILE=""
INTERNAL_SSH_ARGS=()
declare -A INTERNAL_SSH_VALUES=()

INTERNAL_SSH_FAIL() { INTERNAL_SSH_ERROR="$1"; return 1; }

INTERNAL_SSH_VALID_ID() { [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]+$ ]]; }
INTERNAL_SSH_VALID_HOST() { [[ "${1:-}" =~ ^[A-Za-z0-9_.:-]+$ ]]; }
INTERNAL_SSH_VALID_USER() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; }
INTERNAL_SSH_VALID_PORT() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

INTERNAL_SSH_LOAD() {
  local file="${1:-$INTERNAL_SSH_CONFIG_FILE}" line section key value number=0
  INTERNAL_SSH_ERROR=""
  INTERNAL_SSH_VALUES=()
  section=""
  [[ -e "$file" ]] || return 0
  [[ -f "$file" ]] || { INTERNAL_SSH_FAIL "$file is not a regular file"; return 1; }
  [[ -r "$file" ]] || { INTERNAL_SSH_FAIL "$file is not readable"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((number++))
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == schema_version=1 && -z "$section" ]] && continue
    if [[ "$line" =~ ^\[(node|vm|lxc):([A-Za-z0-9_.:-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
      INTERNAL_SSH_VALID_ID "${BASH_REMATCH[2]}" || { INTERNAL_SSH_FAIL "invalid section at line $number"; return 1; }
      continue
    fi
    [[ -n "$section" && "$line" == *=* ]] || { INTERNAL_SSH_FAIL "invalid line $number"; return 1; }
    key="${line%%=*}"; value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    [[ "$key" =~ ^(host|user|port|identity_file|enabled)$ ]] || { INTERNAL_SSH_FAIL "unsupported key '$key' at line $number"; return 1; }
    [[ -z "${INTERNAL_SSH_VALUES[$section|$key]+x}" ]] || { INTERNAL_SSH_FAIL "duplicate key '$key' in [$section]"; return 1; }
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && ${#value} -le 1024 ]] || { INTERNAL_SSH_FAIL "invalid value at line $number"; return 1; }
    case "$key" in
      host) INTERNAL_SSH_VALID_HOST "$value" || { INTERNAL_SSH_FAIL "invalid host"; return 1; } ;;
      user) INTERNAL_SSH_VALID_USER "$value" || { INTERNAL_SSH_FAIL "invalid user"; return 1; } ;;
      port) INTERNAL_SSH_VALID_PORT "$value" || { INTERNAL_SSH_FAIL "invalid port"; return 1; } ;;
      enabled) [[ "$value" == true || "$value" == false ]] || { INTERNAL_SSH_FAIL "invalid enabled value"; return 1; } ;;
      identity_file) [[ "$value" == /* ]] || { INTERNAL_SSH_FAIL "identity_file must be absolute"; return 1; } ;;
    esac
    INTERNAL_SSH_VALUES["$section|$key"]="$value"
  done < "$file" || { INTERNAL_SSH_FAIL "cannot read $file"; return 1; }
}

INTERNAL_SSH_RESOLVE() {
  local kind="$1" id="$2" default_host="$3" default_user="$4" default_port="$5" section value
  INTERNAL_SSH_LOAD "${INTERNAL_SSH_CONFIG_FILE}" || return 1
  section="$kind:$id"
  INTERNAL_SSH_HOST="$default_host"; INTERNAL_SSH_USER="$default_user"; INTERNAL_SSH_PORT="$default_port"
  INTERNAL_SSH_IDENTITY_FILE=""; INTERNAL_SSH_SOURCE="default"
  [[ "${INTERNAL_SSH_VALUES[$section|enabled]:-true}" == true ]] || { INTERNAL_SSH_ENABLED=false; return 0; }
  INTERNAL_SSH_ENABLED=true
  for key in host user port identity_file; do
    value="${INTERNAL_SSH_VALUES[$section|$key]:-}"
    [[ -n "$value" ]] || continue
    case "$key" in host) INTERNAL_SSH_HOST="$value";; user) INTERNAL_SSH_USER="$value";; port) INTERNAL_SSH_PORT="$value";; identity_file) INTERNAL_SSH_IDENTITY_FILE="$value";; esac
    INTERNAL_SSH_SOURCE="override"
  done
  return 0
}

INTERNAL_SSH_USE_IDENTITY() {
  INTERNAL_SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=5)
  if [[ -n "${INTERNAL_SSH_IDENTITY_FILE:-}" ]]; then
    INTERNAL_SSH_ARGS+=(-o IdentitiesOnly=yes -i "$INTERNAL_SSH_IDENTITY_FILE")
  fi
}

INTERNAL_SSH_RESOLVE_NODE() { INTERNAL_SSH_RESOLVE node "$1" "$2" root "${3:-22}"; }
INTERNAL_SSH_RESOLVE_VM() { INTERNAL_SSH_RESOLVE vm "$1" "$2" "$3" "${4:-22}"; }
INTERNAL_SSH_RESOLVE_LXC() { INTERNAL_SSH_RESOLVE lxc "$1" "$2" "$3" "${4:-22}"; }

# Return success when a target has an enabled entry in the data-only internal
# SSH configuration.  This is used for inventory eligibility; an override must
# not be invisible merely because the guest also has (or lacks) QGA enabled.
INTERNAL_SSH_HAS_OVERRIDE() {
  local section="${1:-}:${2:-}"
  INTERNAL_SSH_LOAD "${INTERNAL_SSH_CONFIG_FILE}" || return 1
  [[ -n "${INTERNAL_SSH_VALUES[$section|enabled]+x}" ]] ||
    [[ -n "${INTERNAL_SSH_VALUES[$section|host]+x}" ]] ||
    [[ -n "${INTERNAL_SSH_VALUES[$section|user]+x}" ]] ||
    [[ -n "${INTERNAL_SSH_VALUES[$section|port]+x}" ]] ||
    [[ -n "${INTERNAL_SSH_VALUES[$section|identity_file]+x}" ]] || return 1
  [[ "${INTERNAL_SSH_VALUES[$section|enabled]:-true}" == true ]]
}
