#!/bin/bash
# shellcheck disable=SC2034

# Minimal, dependency-free reader/validator for the optional targets.conf.
# This file defines inventory data only.  It does not execute a transport or
# an updater; those responsibilities belong to later roadmap work.

TARGET_INVENTORY_FILE="${TARGET_INVENTORY_FILE:-/etc/ultimate-updater/targets.conf}"
TARGET_INVENTORY_ERROR=""
# These arrays are the small read interface for later target implementations.
declare -a TARGET_NAMES=()
declare -A TARGET_HOST TARGET_PORT TARGET_TRANSPORT TARGET_USER

TARGET_INVENTORY_FAIL() {
  TARGET_INVENTORY_ERROR="$1"
  return 1
}

TARGET_INVENTORY_TRIM() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

TARGET_INVENTORY_LOAD() {
  local file="${1:-$TARGET_INVENTORY_FILE}"
  local line number section key value
  local -A seen_keys=() seen_sections=()

  TARGET_INVENTORY_ERROR=""
  TARGET_NAMES=()
  TARGET_HOST=()
  TARGET_PORT=()
  TARGET_TRANSPORT=()
  TARGET_USER=()

  # An absent inventory is the compatibility default for existing installs.
  [[ -e "$file" ]] || return 0
  [[ -f "$file" ]] || TARGET_INVENTORY_FAIL "$file is not a regular file"
  [[ -r "$file" ]] || TARGET_INVENTORY_FAIL "$file is not readable"

  section=""
  number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((number++))
    line="$(TARGET_INVENTORY_TRIM "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^\[([a-zA-Z0-9_.-]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      [[ ! -v "seen_sections[$section]" ]] || { TARGET_INVENTORY_FAIL "duplicate target [$section] at line $number"; return 1; }
      seen_sections["$section"]="true"
      TARGET_NAMES+=("$section")
      continue
    fi

    [[ -n "$section" ]] || { TARGET_INVENTORY_FAIL "key outside a target section at line $number"; return 1; }
    [[ "$line" == *=* ]] || { TARGET_INVENTORY_FAIL "invalid line $number (expected key=value)"; return 1; }
    key="${line%%=*}"
    value="${line#*=}"
    key="$(TARGET_INVENTORY_TRIM "$key")"
    value="$(TARGET_INVENTORY_TRIM "$value")"
    [[ "$key" =~ ^(host|port|transport|user)$ ]] || { TARGET_INVENTORY_FAIL "unsupported key '$key' at line $number"; return 1; }
    [[ -n "$value" ]] || { TARGET_INVENTORY_FAIL "empty value for '$key' at line $number"; return 1; }
    [[ ! -v "seen_keys[$section|$key]" ]] || { TARGET_INVENTORY_FAIL "duplicate key '$key' in [$section]"; return 1; }
    seen_keys["$section|$key"]="$value"

    case "$key" in
      host) TARGET_HOST["$section"]="$value" ;;
      port)
        [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )) || { TARGET_INVENTORY_FAIL "invalid port for [$section]"; return 1; }
        TARGET_PORT["$section"]="$value"
        ;;
      transport)
        [[ "$value" =~ ^(local|pct|qga|ssh)$ ]] || { TARGET_INVENTORY_FAIL "unsupported transport '$value' in [$section]"; return 1; }
        TARGET_TRANSPORT["$section"]="$value"
        ;;
      user) TARGET_USER["$section"]="$value" ;;
    esac
  done < "$file" || { TARGET_INVENTORY_FAIL "cannot read $file"; return 1; }

  for section in "${TARGET_NAMES[@]}"; do
    [[ -n "${TARGET_TRANSPORT[$section]:-}" ]] || { TARGET_INVENTORY_FAIL "target [$section] has no transport"; return 1; }
    case "${TARGET_TRANSPORT[$section]}" in
      ssh|qga) [[ -n "${TARGET_HOST[$section]:-}" ]] || { TARGET_INVENTORY_FAIL "target [$section] has no host"; return 1; } ;;
    esac
  done
}

TARGET_INVENTORY_VALIDATE() {
  TARGET_INVENTORY_LOAD "${1:-$TARGET_INVENTORY_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if TARGET_INVENTORY_VALIDATE "${1:-$TARGET_INVENTORY_FILE}"; then
    printf 'Target inventory is valid (%d target%s).\n' "${#TARGET_NAMES[@]}" \
      "$([[ ${#TARGET_NAMES[@]} -eq 1 ]] && printf '' || printf s)"
  else
    printf 'Target inventory error: %s\n' "$TARGET_INVENTORY_ERROR" >&2
    exit 1
  fi
fi
