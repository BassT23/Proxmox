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

external_selection_allows() {
  local mode="$1" target="$2" only_key exclude_key only exclude
  case "$mode" in
    check) only_key=ONLY_UPDATE_CHECK; exclude_key=EXCLUDE_UPDATE_CHECK ;;
    update) only_key=ONLY; exclude_key=EXCLUDE ;;
    *) return 2 ;;
  esac
  only=$(external_selection_config_value "$only_key")
  exclude=$(external_selection_config_value "$exclude_key")
  if [[ -n "$only" ]]; then
    external_selection_matches "$only" "$target" || return 1
  fi
  [[ -z "$exclude" ]] || ! external_selection_matches "$exclude" "$target"
}
