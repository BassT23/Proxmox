#!/usr/bin/env bash
# shellcheck disable=SC1091 # Dynamic test fixture source path is intentional.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/target-selection.json" <<'JSON'
{"schema_version":1,"check":{"host:node1":"only","200":"exclude"},"update":{"210":"only","211":"exclude"}}
JSON

export UU_TARGET_SELECTION_FILE="$WORK_DIR/target-selection.json"
source "$ROOT_DIR/target-selection.sh"
export USE_INTERNAL_TARGET_SELECTION=true
export UU_FILTER_SCOPE=check
[[ "$(TARGET_SELECTION_STATE check '100 200 300')" == '' ]] # host-only rule excludes all guest IDs
[[ "$(TARGET_SELECTION_STATE check 'host:node1 host:node2')" == 'host:node1' ]]
export UU_FILTER_SCOPE=update
[[ "$(TARGET_SELECTION_STATE update '200 210 211 212')" == '210' ]]
TARGET_SELECTION_ALLOWS update 210 '200 210 211 212'
if TARGET_SELECTION_ALLOWS update 211 '200 210 211 212'; then exit 1; fi
TARGET_SELECTION_HOST_REQUIRED check host:node1
TARGET_SELECTION_HOST_REQUIRED check host:node2
TARGET_SELECTION_HOST_REQUIRED update host:node2

USE_INTERNAL_TARGET_SELECTION=false
TARGET_SELECTION_ALLOWS check 200 '100 200'

INIT_FILE="$WORK_DIR/initial-target-selection.json"
export UU_TARGET_SELECTION_FILE="$INIT_FILE"
TARGET_SELECTION_FILE="$INIT_FILE"
TARGET_SELECTION_INITIALIZE
[[ "$(stat -c '%a' "$INIT_FILE")" == 600 ]]
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["schema_version"])' "$INIT_FILE")" == 1 ]]
[[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["check"], d["update"])' "$INIT_FILE")" == '{} {}' ]]
printf '%s\n' '{"schema_version":1,"check":{"host:node1":"only"},"update":{}}' > "$INIT_FILE"
before=$(sha256sum "$INIT_FILE")
TARGET_SELECTION_INITIALIZE
[[ "$(sha256sum "$INIT_FILE")" == "$before" ]]
echo 'target selection engine tests: PASS'
