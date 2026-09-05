#!/bin/bash

# Safe, allowlisted configuration for one External Linux system.
# This file is intentionally independent from the cluster update.conf.

EXTERNAL_CONFIG_FILE="${EXTERNAL_CONFIG_FILE:-/etc/ultimate-updater/external.conf}"
EXTERNAL_CONFIG_SCHEMA=1
external_config_key_allowed() {
  case "$1" in
    ONLY_UPDATE_CHECK|EXCLUDE_UPDATE_CHECK|ONLY|EXCLUDE) return 0 ;;
    *) return 1 ;;
  esac
}

external_config_value() {
  local file="$1" key="$2"
  external_config_key_allowed "$key" || return 2
  [[ -r "$file" ]] || return 1
  awk -F= -v wanted="$key" '
    $1 == wanted {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((value ~ /^".*"$/) || (value ~ /^'"'"'.*'"'"'$/))
        value = substr(value, 2, length(value) - 2)
      print value
      exit
    }
  ' "$file"
}

external_config_validate() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || return 2
  awk -F= -v schema="$EXTERNAL_CONFIG_SCHEMA" '
    function fail(message) { print message > "/dev/stderr"; bad=1; exit }
    /^[[:space:]]*($|#)/ { next }
    {
      key=$1
      if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/) fail("invalid key")
      if (seen[key]++) fail("duplicate key: " key)
      value=substr($0, index($0, "=") + 1)
      if (length(value) > 513 || value ~ /[\r\n]/) fail("invalid value")
      if (key == "schema_version") {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != schema && value != "\"" schema "\"") fail("unsupported schema")
      } else if (key != "ONLY_UPDATE_CHECK" && key != "EXCLUDE_UPDATE_CHECK" &&
                 key != "ONLY" && key != "EXCLUDE") fail("unsupported key: " key)
    }
    END { if (!seen["schema_version"]) fail("schema_version is required"); exit(bad ? 1 : 0) }
  ' "$file"
}

external_config_defaults() {
  printf 'schema_version="%s"\n' "$EXTERNAL_CONFIG_SCHEMA"
  printf 'ONLY_UPDATE_CHECK=""\nEXCLUDE_UPDATE_CHECK=""\nONLY=""\nEXCLUDE=""\n'
}

external_config_filter_match() {
  local specification="$1" candidate="$2" token normalized
  [[ -n "$specification" ]] || return 1
  normalized=$(printf '%s' "$specification" | tr ',;|' '   ')
  for token in $normalized; do
    [[ "${token,,}" == "${candidate,,}" ]] && return 0
  done
  return 1
}

external_config_allows() {
  local file="$1" action="$2" candidate="$3" only_key exclude_key only exclude
  case "$action" in
    check) only_key=ONLY_UPDATE_CHECK; exclude_key=EXCLUDE_UPDATE_CHECK ;;
    update) only_key=ONLY; exclude_key=EXCLUDE ;;
    *) return 2 ;;
  esac
  only=$(external_config_value "$file" "$only_key") || return 2
  exclude=$(external_config_value "$file" "$exclude_key") || return 2
  if [[ -n "$only" ]]; then
    external_config_filter_match "$only" "$candidate"
    return $?
  fi
  if [[ -n "$exclude" ]] && external_config_filter_match "$exclude" "$candidate"; then
    return 1
  fi
  return 0
}
