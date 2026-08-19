#!/bin/bash

# Side-effect-free central selection for External targets.
EXTERNAL_SELECTION_CONFIG_FILE="${EXTERNAL_SELECTION_CONFIG_FILE:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/update.conf}"

external_selection_config_value() {
  local wanted="$1"
  awk -F'"' -v wanted="$wanted" '$1 ~ "^" wanted "=" {print $2; exit}' \
    "$EXTERNAL_SELECTION_CONFIG_FILE" 2>/dev/null || true
}

external_selection_matches() {
  local specification="$1" target="$2" token normalized
  normalized=$(printf '%s' "$specification" | tr ',;|' '   ')
  for token in $normalized; do
    [[ "${token,,}" == "${target,,}" ]] && return 0
  done
  return 1
}

external_selection_only_active() {
  local mode="$1" only="$2" config_file="$EXTERNAL_SELECTION_CONFIG_FILE"
  local only_value="$only" exclude_value="" scope
  [[ -n "$only_value" ]] || return 1
  scope=$([[ "$mode" == check ]] && printf check || printf update)
  local tag_filter
  tag_filter="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/tag-filter.sh"
  [[ -f "$tag_filter" ]] || return 0
  local with_lxc with_vm running_ct stopped_ct running_vm stopped_vm paused_vm
  if [[ "$mode" == check ]]; then
    with_lxc=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' "$config_file" 2>/dev/null)
    with_vm=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' "$config_file" 2>/dev/null)
    running_ct=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' "$config_file" 2>/dev/null)
    stopped_ct=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' "$config_file" 2>/dev/null)
    running_vm=$(awk -F'"' '/^CHECK_RUNNING_VM=/ {print $2}' "$config_file" 2>/dev/null)
    stopped_vm=$(awk -F'"' '/^CHECK_STOPPED_VM=/ {print $2}' "$config_file" 2>/dev/null)
    paused_vm=$(awk -F'"' '/^CHECK_PAUSED_VM=/ {print $2}' "$config_file" 2>/dev/null)
  else
    with_lxc=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$config_file" 2>/dev/null)
    with_vm=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$config_file" 2>/dev/null)
    running_ct=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$config_file" 2>/dev/null)
    stopped_ct=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$config_file" 2>/dev/null)
    running_vm=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$config_file" 2>/dev/null)
    stopped_vm=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$config_file" 2>/dev/null)
  fi
  local only_result
  only_result=$(ONLY="$only_value" EXCLUDE="$exclude_value" UU_FILTER_SCOPE="$scope" \
    WITH_LXC="$with_lxc" WITH_VM="$with_vm" RUNNING="$running_ct" STOPPED="$stopped_ct" \
    RUNNING_VM="$running_vm" STOPPED_VM="$stopped_vm" PAUSED_VM="$paused_vm" \
    bash -c 'source "$1"; apply_only_exclude_tags ONLY EXCLUDE; printf "%s" "$ONLY"' \
    external-selection-filter "$tag_filter" 2>/dev/null) || return 0
  [[ -n "$only_result" ]]
}

external_selection_allows() {
  local mode="$1" target="$2" only_key exclude_key only exclude
  case "$mode" in
    check) only_key=ONLY_UPDATE_CHECK; exclude_key=EXCLUDE_UPDATE_CHECK ;;
    update) only_key=ONLY; exclude_key=EXCLUDE ;;
    *) return 2 ;;
  esac
  only=$(external_selection_config_value "$only_key")
  exclude=$(external_selection_config_value "$exclude_key")
  if [[ -n "$only" ]] && external_selection_only_active "$mode" "$only"; then
    external_selection_matches "$only" "$target" || return 1
  fi
  [[ -z "$exclude" ]] || ! external_selection_matches "$exclude" "$target"
}
