#!/usr/bin/env bash
# Clean up legacy migration artifacts without treating VM SSH profiles as
# External targets. /etc/ultimate-updater/VMs/<ID> remains an internal VM path.
# Legacy files are data, not shell programs: never source or eval them.
# shellcheck disable=SC2094

set -u
LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
LEGACY_DIR="${UU_LEGACY_DIR:-$LOCAL_FILES/VMs}"
TARGETS_FILE="${UU_TARGETS_FILE:-$LOCAL_FILES/targets.conf}"
STATE_FILE="${UU_LEGACY_STATE_FILE:-$LOCAL_FILES/legacy-migration.state}"
MIGRATION_LOG="${UU_LEGACY_MIGRATION_LOG:-$LOCAL_FILES/legacy-migration.log}"
INVENTORY_SCRIPT="${UU_TARGET_INVENTORY_SCRIPT:-$LOCAL_FILES/target-inventory.sh}"
[[ -x "$INVENTORY_SCRIPT" ]] || INVENTORY_SCRIPT="${BASH_SOURCE[0]%/*}/target-inventory.sh"

MIGRATED=0
REMOVED=0
ALREADY_PRESENT=0
SKIPPED_INVALID=0
MANUAL_REVIEW=0
declare -a REPORT=() ADDITIONS=()

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}
report() {
  REPORT+=("$1")
  if [[ "${UU_LEGACY_MIGRATION_VERBOSE:-false}" == true ]]; then
    printf '%s\n' "$1"
  fi
}
fail_invalid() {
  local file="$1" reason="$2"
  ((SKIPPED_INVALID++))
  report "SKIPPED_INVALID $file: $reason"
}
unquote_value() {
  local value="$1"
  if [[ "$value" == \"* ]]; then
    value="${value#\"}"
    [[ "$value" == *\"* ]] || return 1
    value="${value%%\"*}"
  elif [[ "$value" == \'* ]]; then
    value="${value#\'}"
    [[ "$value" == *\'* ]] || return 1
    value="${value%%\'*}"
  fi
  printf '%s' "$value"
}
safe_value() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ "$value" != *'$'* && "$value" != *'('* && "$value" != *')'* ]] || return 1
  [[ "$value" != *';'* && "$value" != *'|'* && "$value" != *'>'* && "$value" != *'<'* ]] || return 1
}
parse_legacy() {
  local file="$1" line key value number=0
  LEGACY_IP="" LEGACY_USER="" LEGACY_PORT="22" LEGACY_DELAY=""
  LEGACY_UNKNOWN=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((number++))
    line="$(trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || { fail_invalid "$file" "invalid assignment at line $number"; return 1; }
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { fail_invalid "$file" "invalid key at line $number"; return 1; }
    value="$(unquote_value "$value")" || {
      fail_invalid "$file" "unterminated quoted value at line $number"
      return 1
    }
    if ! safe_value "$value"; then
      fail_invalid "$file" "unsafe value for $key at line $number"; return 1
    fi
    case "$key" in
      IP) LEGACY_IP="$value" ;;
      USER) LEGACY_USER="$value" ;;
      SSH_VM_PORT) LEGACY_PORT="$value" ;;
      SSH_START_DELAY_TIME) LEGACY_DELAY="$value" ;;
      *) LEGACY_UNKNOWN+=("$key") ;;
    esac
  done < "$file" || { fail_invalid "$file" "cannot read file"; return 1; }
  [[ -n "$LEGACY_IP" ]] || { fail_invalid "$file" "IP is missing"; return 1; }
  [[ "$LEGACY_IP" =~ ^[A-Za-z0-9_.:-]+$ ]] || { fail_invalid "$file" "invalid IP/host"; return 1; }
  [[ -n "$LEGACY_USER" && "$LEGACY_USER" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { fail_invalid "$file" "invalid USER"; return 1; }
  if ! [[ "$LEGACY_PORT" =~ ^[0-9]+$ ]] || ((LEGACY_PORT < 1 || LEGACY_PORT > 65535 )); then
    fail_invalid "$file" "invalid SSH_VM_PORT"; return 1
  fi
  if (( ${#LEGACY_UNKNOWN[@]} > 0 )); then report "IGNORED_UNKNOWN $file: ${LEGACY_UNKNOWN[*]}"; fi
  if [[ -n "$LEGACY_DELAY" ]]; then
    [[ "$LEGACY_DELAY" =~ ^[0-9]+$ ]] || { fail_invalid "$file" "invalid SSH_START_DELAY_TIME"; return 1; }
    report "UNMAPPED_LEGACY_VALUE $file: SSH_START_DELAY_TIME is deprecated and has no targets.conf equivalent"
  fi
}
backup_targets() {
  local backup stamp=0
  [[ -e "$TARGETS_FILE" ]] || return 0
  while :; do
    backup="${TARGETS_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    ((stamp++))
    [[ $stamp -eq 1 ]] || backup="${TARGETS_FILE}.bak.$(date +%Y%m%d-%H%M%S).$stamp"
    [[ ! -e "$backup" ]] && break
    sleep 1
  done
  cp -p -- "$TARGETS_FILE" "$backup"
  report "Backup: $backup"
}
validate_inventory() {
  TARGET_INVENTORY_VALIDATE "$1" >/dev/null
}
write_additions() {
  local tmp addition
  tmp="$(mktemp "${TARGETS_FILE}.migration.XXXXXX")" || return 1
  if [[ -e "$TARGETS_FILE" ]]; then cat -- "$TARGETS_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }; fi
  for addition in "${ADDITIONS[@]}"; do printf '\n%s\n' "$addition" >>"$tmp" || { rm -f "$tmp"; return 1; }; done
  if ! validate_inventory "$tmp"; then
    rm -f "$tmp"; printf 'Migration validation failed; original targets.conf was kept.\n' >&2; return 1
  fi
  backup_targets || { rm -f "$tmp"; return 1; }
  chmod --reference="$TARGETS_FILE" "$tmp" 2>/dev/null || chmod 640 "$tmp"
  mv -f -- "$tmp" "$TARGETS_FILE"
}
write_state() {
  local tmp fingerprint
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")" || return 1
  fingerprint="$(legacy_fingerprint)"
  { printf 'fingerprint=%s\n' "$fingerprint"; printf 'manual_review=%s\n' "$MANUAL_REVIEW"; } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"; mv -f -- "$tmp" "$STATE_FILE"
}
legacy_fingerprint() {
  find "$LEGACY_DIR" -maxdepth 1 -type f ! -name example -printf '%f\n' |
    LC_ALL=C sort |
    while IFS= read -r file; do sha256sum "$LEGACY_DIR/$file"; done |
    sha256sum | awk '{print $1}'
}
legacy_inventory_complete() {
  local file
  [[ -f "$TARGETS_FILE" ]] || return 1
  while IFS= read -r file; do
    [[ "$file" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    grep -Eq "^\[legacy-${file//./\.}\][[:space:]]*$" "$TARGETS_FILE" || return 1
  done < <(find "$LEGACY_DIR" -maxdepth 1 -type f ! -name example -printf '%f\n' | LC_ALL=C sort)
}
legacy_migration_evidence() {
  [[ -f "$STATE_FILE" ]] || return 1
  grep -Eq '^manual_review=' "$STATE_FILE"
}
remove_legacy_sections() {
  local tmp remove_list section
  (( ${#ADDITIONS[@]} > 0 )) || return 0
  tmp="$(mktemp "${TARGETS_FILE}.cleanup.XXXXXX")" || return 1
  remove_list="$(IFS=,; printf '%s' "${ADDITIONS[*]}")"
  awk -v remove_list="$remove_list" '
    BEGIN {
      count = split(remove_list, values, ",")
      for (i = 1; i <= count; i++) remove[values[i]] = 1
      drop = 0
    }
    /^\[[^]]+\][[:space:]]*$/ {
      name = $0
      sub(/^\[/, "", name); sub(/\][[:space:]]*$/, "", name)
      drop = (name in remove)
    }
    !drop { print }
  ' "$TARGETS_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
  if ! validate_inventory "$tmp"; then
    rm -f "$tmp"
    printf 'Cleanup validation failed; original targets.conf was kept.\n' >&2
    return 1
  fi
  backup_targets || { rm -f "$tmp"; return 1; }
  chmod --reference="$TARGETS_FILE" "$tmp" 2>/dev/null || chmod 640 "$tmp"
  mv -f -- "$tmp" "$TARGETS_FILE"
  REMOVED=${#ADDITIONS[@]}
  for section in "${ADDITIONS[@]}"; do report "REMOVED_BUG_GENERATED [$section]"; done
}
cleanup_legacy_external_entries() {
  local file section base
  [[ -d "$LEGACY_DIR" && -f "$TARGETS_FILE" ]] || return 0
  legacy_migration_evidence || return 0
  [[ -x "$INVENTORY_SCRIPT" ]] || { printf 'Cannot validate targets.conf: inventory parser missing.\n' >&2; return 1; }
  validate_inventory "$TARGETS_FILE" || { printf 'Existing targets.conf is invalid; cleanup stopped safely.\n' >&2; return 1; }
  mapfile -t LEGACY_FILES < <(find "$LEGACY_DIR" -maxdepth 1 -type f ! -name example -printf '%f\n' | LC_ALL=C sort)
  for file in "${LEGACY_FILES[@]}"; do
    [[ "$file" =~ ^[0-9]+$ ]] || continue
    parse_legacy "$LEGACY_DIR/$file" || continue
    base="legacy-$file"
    [[ "${TARGET_HOST[$base]:-}" == "$LEGACY_IP" &&
      "${TARGET_USER[$base]:-}" == "$LEGACY_USER" &&
      "${TARGET_PORT[$base]:-22}" == "$LEGACY_PORT" ]] || continue
    ADDITIONS+=("$base")
  done
  remove_legacy_sections
}
write_report_log() {
  local temporary
  [[ ${#REPORT[@]} -gt 0 ]] || return 0
  temporary="$(mktemp "${MIGRATION_LOG}.XXXXXX")" || return 1
  {
    printf 'Legacy SSH migration\n'
    printf '%s\n' "${REPORT[@]}"
    printf 'Migrated: %d\nAlready present: %d\nSkipped invalid: %d\nManual review required: %d\n' \
      "$MIGRATED" "$ALREADY_PRESENT" "$SKIPPED_INVALID" "$MANUAL_REVIEW"
  } >"$temporary" || { rm -f "$temporary"; return 1; }
  chmod 640 "$temporary"
  mv -f -- "$temporary" "$MIGRATION_LOG"
}
if [[ -f "$STATE_FILE" && -d "$LEGACY_DIR" ]]; then
  previous_fingerprint="$(awk -F= '$1 == "fingerprint" {print $2}' "$STATE_FILE")"
  previous_review="$(awk -F= '$1 == "manual_review" {print $2}' "$STATE_FILE")"
  if [[ "$previous_review" == 0 && "$previous_fingerprint" == "$(legacy_fingerprint)" ]] &&
    legacy_inventory_complete; then
    exit 0
  fi
fi
if [[ "${UU_LEGACY_MIGRATION_VERBOSE:-false}" == true ]]; then
  printf 'Legacy SSH migration\n'
fi
# The inventory parser is repository code, unlike the legacy files. Source it
# once at top level so its validated arrays remain available for duplicate
# detection.
# shellcheck disable=SC1090
source "$INVENTORY_SCRIPT"
cleanup_legacy_external_entries || exit 1
write_report_log || { printf 'Could not write legacy migration details to %s\n' "$MIGRATION_LOG" >&2; exit 1; }
if (( REMOVED > 0 )); then
  printf '✅ Removed %d obsolete internal VM SSH entries from external target management.\n' "$REMOVED"
fi
if (( SKIPPED_INVALID > 0 )); then
  printf '⚠ %d legacy SSH configurations were skipped because they are invalid.\n' "$SKIPPED_INVALID"
fi
if (( MANUAL_REVIEW > 0 )); then
  printf '⚠ %d legacy SSH configurations require manual review.\n' "$MANUAL_REVIEW"
fi
if (( SKIPPED_INVALID > 0 || MANUAL_REVIEW > 0 )); then
  printf '%s\n' "${REPORT[@]}"
elif (( MIGRATED > 0 )); then
  printf '✅ %d existing SSH systems successfully migrated to the new target management.\n' "$MIGRATED"
elif (( ALREADY_PRESENT > 0 )); then
  printf '✅ Existing SSH systems are already integrated into the new target management.\n'
fi
