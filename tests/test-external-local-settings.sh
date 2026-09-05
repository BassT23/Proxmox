#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

CONFIG="$WORK_DIR/external.conf"
# shellcheck disable=SC1090,SC1091
EXTERNAL_CONFIG_FILE="$CONFIG" source "$ROOT_DIR/external-config.sh"

external_config_defaults > "$CONFIG"
external_config_validate "$CONFIG"
[[ "$(external_config_value "$CONFIG" ONLY_UPDATE_CHECK)" == '' ]]
external_config_allows "$CONFIG" check target
external_config_allows "$CONFIG" update target

sed -i 's/ONLY_UPDATE_CHECK=""/ONLY_UPDATE_CHECK="monitoring"/; s/EXCLUDE_UPDATE_CHECK=""/EXCLUDE_UPDATE_CHECK="monitoring"/' "$CONFIG"
external_config_allows "$CONFIG" check monitoring
if external_config_allows "$CONFIG" check other; then
  echo 'check ONLY filter did not restrict the target' >&2
  exit 1
fi

sed -i 's/ONLY_UPDATE_CHECK="monitoring"/ONLY_UPDATE_CHECK=""/' "$CONFIG"
external_config_allows "$CONFIG" check other
if external_config_allows "$CONFIG" check monitoring; then
  echo 'check EXCLUDE filter did not exclude the target' >&2
  exit 1
fi

sed -i 's/ONLY=""/ONLY="stable"/; s/EXCLUDE=""/EXCLUDE="stable"/' "$CONFIG"
external_config_allows "$CONFIG" update stable
if external_config_allows "$CONFIG" update other; then
  echo 'update ONLY did not take precedence over EXCLUDE' >&2
  exit 1
fi

cp "$CONFIG" "$WORK_DIR/original"
printf '\nUNKNOWN="nope"\n' >> "$CONFIG"
if external_config_validate "$CONFIG" >/dev/null 2>&1; then
  echo 'unknown External setting was accepted' >&2
  exit 1
fi
cp "$WORK_DIR/original" "$CONFIG"

HELPER="$WORK_DIR/helper"
sed "s#^CONFIG_PATH=.*#CONFIG_PATH=$CONFIG#" "$ROOT_DIR/external-helper.sh" > "$HELPER"
chmod 0755 "$HELPER"
"$HELPER" config-read >/dev/null
if [[ "$(id -u)" -eq 0 ]]; then
  printf '%s\n' 'schema_version="1"' 'ONLY_UPDATE_CHECK="A"' 'EXCLUDE_UPDATE_CHECK=""' 'ONLY="B"' 'EXCLUDE=""' |
    "$HELPER" config-write >/dev/null
  [[ "$(stat -c '%a' "$CONFIG")" == 644 ]]
  [[ "$(stat -c '%U:%G' "$CONFIG")" == root:root ]]
  [[ -n "$(find "$WORK_DIR" -maxdepth 1 -name 'external.conf.bak.*' -print -quit)" ]]
fi
if [[ "$(id -u)" -eq 0 ]]; then
  runuser -u nobody -- "$HELPER" config-write </dev/null >/dev/null 2>&1 && {
    echo 'non-root External config write was accepted' >&2
    exit 1
  }
elif "$HELPER" config-write </dev/null >/dev/null 2>&1; then
  echo 'non-root External config write was accepted' >&2
  exit 1
fi

echo 'External local settings tests: PASS'
