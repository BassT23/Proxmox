#!/bin/bash

# External Linux target support over SSH.
# This historically named file owns SSH discovery and ordinary apt/dnf actions.

set -o pipefail

LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
INVENTORY_SCRIPT="${TARGET_INVENTORY_SCRIPT:-$LOCAL_FILES/target-inventory.sh}"
STATUS_MODEL_SCRIPT="${STATUS_MODEL_SCRIPT:-$LOCAL_FILES/status-model.sh}"
INVENTORY_FILE="${TARGET_INVENTORY_FILE:-$LOCAL_FILES/targets.conf}"
RUNTIME_SCRIPT="${TARGET_RUNTIME_SCRIPT:-$LOCAL_FILES/target-runtime.sh}"
[[ -f "$INVENTORY_SCRIPT" ]] || INVENTORY_SCRIPT="$SCRIPT_DIR/target-inventory.sh"
[[ -f "$STATUS_MODEL_SCRIPT" ]] || STATUS_MODEL_SCRIPT="$SCRIPT_DIR/status-model.sh"
[[ -f "$RUNTIME_SCRIPT" ]] || RUNTIME_SCRIPT="$SCRIPT_DIR/target-runtime.sh"
# shellcheck disable=SC1090
source "$INVENTORY_SCRIPT"
# shellcheck disable=SC1090
source "$STATUS_MODEL_SCRIPT"
TARGET_INVENTORY_FILE="$INVENTORY_FILE"
# shellcheck disable=SC1090
if [[ -f "$RUNTIME_SCRIPT" ]]; then
  source "$RUNTIME_SCRIPT"
else
  RUN_SSH_COMMAND() {
    local host="$1" port="$2" user="$3"
    shift 3
    ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"
  }
fi

usage() { printf 'Usage: %s check TARGET | TARGET\n' "$0"; }

load_target() {
  local target="$1"
  TARGET_INVENTORY_VALIDATE "${TARGET_INVENTORY_FILE:-$LOCAL_FILES/targets.conf}" || {
    printf 'external-linux: invalid target inventory: %s\n' "$TARGET_INVENTORY_ERROR" >&2
    return 2
  }
  [[ -n "${TARGET_TRANSPORT[$target]:-}" ]] || {
    printf 'external-linux: target not found: %s\n' "$target" >&2
    return 3
  }
  [[ "${TARGET_TRANSPORT[$target]}" == ssh ]] || {
    printf 'external-linux: target %s does not use SSH\n' "$target" >&2
    return 2
  }
  EXTERNAL_TARGET="$target"
  EXTERNAL_HOST="${TARGET_HOST[$target]}"
  EXTERNAL_PORT="${TARGET_PORT[$target]:-22}"
  EXTERNAL_USER="${TARGET_USER[$target]:-root}"
}

classify_ssh_error() {
  local output="${1,,}"
  if [[ "$output" == *"permission denied"* || "$output" == *"authentication"* ]]; then
    printf 'AUTH_FAILED'
  elif [[ "$output" == *"could not resolve"* || "$output" == *"connection timed out"* ||
    "$output" == *"no route to host"* || "$output" == *"network is unreachable"* ||
    "$output" == *"connection refused"* ]]; then
    printf 'SSH_UNREACHABLE'
  else
    printf 'SSH_CONNECTION_FAILED'
  fi
}

remote_check() {
  RUN_SSH_COMMAND "$EXTERNAL_HOST" "$EXTERNAL_PORT" "$EXTERNAL_USER" 'bash -s' <<'REMOTE_CHECK'
set -u
if [ ! -r /etc/os-release ]; then
  printf 'UU_RESULT|error|unknown|unknown|null|null||OS_RELEASE_UNAVAILABLE|/etc/os-release is unavailable\n'
  exit 20
fi
. /etc/os-release
id_lower=$(printf '%s %s' "${ID:-}" "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
case "$id_lower" in
  *debian*|*ubuntu*|*raspbian*) updater=apt ;;
  *rocky*|*rhel*|*almalinux*|*fedora*) updater=dnf ;;
  *) printf 'UU_RESULT|unsupported|%s|%s|null|null||UNSUPPORTED_OS|%s\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}" "${ID:-unknown}"; exit 21 ;;
esac
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  SUDO="sudo -n"
else
  printf 'UU_RESULT|error|%s|%s|null|null||INSUFFICIENT_PRIVILEGES|root or passwordless sudo is required\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
  exit 23
fi
if ! command -v "$updater" >/dev/null 2>&1; then
  printf 'UU_RESULT|error|%s|%s|null|null|%s|%s_UNAVAILABLE|%s is unavailable\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}" "$updater" "${updater^^}" "$updater"
  exit 24
fi
if [ "$updater" = apt ]; then
  if ! $SUDO apt-get update >/dev/null 2>&1; then
    printf 'UU_RESULT|error|%s|%s|null|null|apt|APT_CHECK_FAILED|apt-get update failed\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
    exit 25
  fi
  apt_output=$($SUDO apt-get -s upgrade 2>&1) || {
    printf 'UU_RESULT|error|%s|%s|null|null|apt|APT_CHECK_FAILED|apt simulation failed\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
    exit 25
  }
  updates=$(printf '%s\n' "$apt_output" | grep -ci '^inst ' || true)
  reboot=false
  if [ -e /var/run/reboot-required ] || [ -e /var/run/reboot-required.pkgs ]; then reboot=true; fi
else
  dnf_output=$($SUDO dnf -q check-update 2>&1)
  dnf_status=$?
  if [ "$dnf_status" -ne 0 ] && [ "$dnf_status" -ne 100 ]; then
    printf 'UU_RESULT|error|%s|%s|null|null|dnf|DNF_CHECK_FAILED|dnf check-update failed\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}"
    exit 25
  fi
  if [ "$dnf_status" -eq 0 ]; then
    updates=0
  else
    updates=$(printf '%s\n' "$dnf_output" | awk 'NF >= 3 && $2 ~ /^[0-9]/ {count++} END {print count + 0}')
  fi
  reboot=null
  if command -v needs-restarting >/dev/null 2>&1; then
    $SUDO needs-restarting -r >/dev/null 2>&1
    needs_restarting_status=$?
    case "$needs_restarting_status" in
      0) reboot=false ;;
      1) reboot=true ;;
      *) reboot=null ;;
    esac
  fi
fi
printf 'UU_RESULT|ok|%s|%s|%s|%s|%s|||\n' "${PRETTY_NAME:-unknown}" "${VERSION_ID:-}" "$updates" "$reboot" "$updater"
REMOTE_CHECK
}

record_check_error() {
  local reachable="$1" status="$2" code="$3" message="$4"
  STATUS_MODEL_UPSERT "$EXTERNAL_TARGET" external ssh "$reachable" "" "" "" null null "$status" "$code" "$message"
}

check_target() {
  local result rc marker check_status os_name os_version updates reboot updater code message
  result=$(remote_check 2>&1)
  rc=$?
  if [[ $rc -ne 0 && "$result" != UU_RESULT\|* ]]; then
    code=$(classify_ssh_error "$result")
    record_check_error false offline "$code" "SSH connection failed: $result"
    printf 'external-linux: %s: %s\n' "$EXTERNAL_TARGET" "$result" >&2
    return 1
  fi
  IFS='|' read -r marker check_status os_name os_version updates reboot updater code message <<< "$result"
  if [[ "$marker" != UU_RESULT ]]; then
    record_check_error true error REMOTE_CHECK_FAILED "Unexpected remote check response"
    return 1
  fi
  case "$check_status" in
    ok)
      local state=ok
      [[ "$updates" -gt 0 || "$reboot" == true ]] && state=updates_available
      STATUS_MODEL_UPSERT "$EXTERNAL_TARGET" external ssh true "$os_name" "$os_version" "$updater" "$updates" "$reboot" "$state" "" ""
      printf '%s: %s, %s updates, reboot_required=%s\n' "$EXTERNAL_TARGET" "$os_name" "$updates" "$reboot"
      ;;
    unsupported|error)
      STATUS_MODEL_UPSERT "$EXTERNAL_TARGET" external ssh true "$os_name" "$os_version" "" null null "$check_status" "${code:-REMOTE_CHECK_FAILED}" "${message:-Remote check failed}"
      printf 'external-linux: %s: %s\n' "$EXTERNAL_TARGET" "${message:-Remote check failed}" >&2
      return 1
      ;;
    *)
      record_check_error true error REMOTE_CHECK_FAILED "Unknown remote check status: $check_status"
      return 1
      ;;
  esac
}

remote_update() {
  RUN_SSH_COMMAND "$EXTERNAL_HOST" "$EXTERNAL_PORT" "$EXTERNAL_USER" 'bash -s' <<'REMOTE_UPDATE'
set -u
if [ ! -r /etc/os-release ]; then exit 20; fi
. /etc/os-release
id_lower=$(printf '%s %s' "${ID:-}" "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then SUDO="sudo -n"; else exit 23; fi
case "$id_lower" in
  *debian*|*ubuntu*|*raspbian*)
    command -v apt-get >/dev/null 2>&1 || exit 24
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get --purge autoremove -y
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get autoclean -y
    ;;
  *rocky*|*rhel*|*almalinux*|*fedora*)
    command -v dnf >/dev/null 2>&1 || exit 24
    $SUDO dnf -y upgrade
    ;;
  *) exit 21 ;;
esac
REMOTE_UPDATE
}

update_target() {
  local output rc code
  output=$(remote_update 2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    STATUS_MODEL_UPDATE_RESULT "$EXTERNAL_TARGET" success 0 || true
    printf '%s: update completed successfully\n' "$EXTERNAL_TARGET"
    return 0
  fi
  code=$(classify_ssh_error "$output")
  [[ "$code" == SSH_* || "$code" == AUTH_FAILED ]] || code=APT_UPDATE_FAILED
  STATUS_MODEL_UPDATE_RESULT "$EXTERNAL_TARGET" failed "$rc" || true
  printf 'external-linux: %s: update failed (%s): %s\n' "$EXTERNAL_TARGET" "$code" "$output" >&2
  return "$rc"
}

main() {
  local action target
  if [[ $# -eq 1 ]]; then action=update; target="$1"; elif [[ $# -eq 2 && "$1" == check ]]; then action=check; target="$2"; else usage >&2; return 2; fi
  load_target "$target" || return $?
  case "$action" in check) check_target ;; update) update_target ;; esac
}

main "$@"
