#!/bin/bash

# Cluster-wide update dispatcher.  The existing update.sh owns Proxmox
# Nodes/LXC/VMs; this wrapper adds managed External SSH targets at the same
# global job boundary without changing the legacy updater's target logic.

set -o pipefail

LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
UPDATE_SCRIPT="${UU_UPDATE_SCRIPT:-$LOCAL_FILES/update.sh}"
EXTERNAL_SCRIPT="${UU_EXTERNAL_SCRIPT:-$LOCAL_FILES/external-apt.sh}"
INVENTORY_SCRIPT="${UU_INVENTORY_SCRIPT:-$LOCAL_FILES/target-inventory.sh}"
CONFIG_FILE="${UU_CONFIG_FILE:-$LOCAL_FILES/update.conf}"
SELECTION_SCRIPT="${UU_SELECTION_SCRIPT:-$LOCAL_FILES/external-selection.sh}"
[[ -f "$SELECTION_SCRIPT" ]] || SELECTION_SCRIPT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/external-selection.sh"
export EXTERNAL_SELECTION_CONFIG_FILE="$CONFIG_FILE"
# shellcheck disable=SC1090
source "$SELECTION_SCRIPT"

run_external_updates() {
  local target rc result=0 has_external=false
  [[ -f "$INVENTORY_SCRIPT" ]] || return 0
  # shellcheck disable=SC1090
  source "$INVENTORY_SCRIPT"
  TARGET_INVENTORY_VALIDATE "$LOCAL_FILES/targets.conf" || {
    printf 'UPDATE external-linux: inventory invalid; External updates blocked\n' >&2
    return 1
  }
  for target in "${TARGET_NAMES[@]}"; do
    [[ "${TARGET_TRANSPORT[$target]:-}" == ssh ]] && { has_external=true; break; }
  done
  if [[ "$has_external" == true && ! -f "$EXTERNAL_SCRIPT" ]]; then
    printf 'UPDATE external-linux: external update helper is unavailable\n' >&2
    return 1
  fi
  for target in "${TARGET_NAMES[@]}"; do
    [[ "${TARGET_TRANSPORT[$target]:-}" == ssh ]] || continue
    if ! external_selection_allows update "$target"; then
      printf 'UPDATE external-linux: %s skipped by central update filter\n' "$target"
      continue
    fi
    printf 'UPDATE external-linux: %s selected\n' "$target"
    "$EXTERNAL_SCRIPT" "$target"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 42 ]]; then
        printf 'UPDATE external-linux: %s blocked by backup safety\n' "$target" >&2
      else
        printf 'UPDATE external-linux: %s failed (exit code %s)\n' "$target" "$rc" >&2
      fi
      [[ "$result" -ne 0 ]] || result="$rc"
      [[ "${EXIT_ON_ERROR:-false}" == true ]] && break
    fi
  done
  return "$result"
}

main() {
  local core_result external_result exit_on_error
  [[ -x "$UPDATE_SCRIPT" ]] || { printf 'Global update script is unavailable: %s\n' "$UPDATE_SCRIPT" >&2; return 1; }
  exit_on_error=$(external_selection_config_value EXIT_ON_ERROR)
  export EXIT_ON_ERROR="$exit_on_error"
  "$UPDATE_SCRIPT"
  core_result=$?
  if [[ "$core_result" -ne 0 && "$exit_on_error" == true ]]; then
    return "$core_result"
  fi
  run_external_updates
  external_result=$?
  [[ "$core_result" -eq 0 ]] || return "$core_result"
  return "$external_result"
}

main "$@"
