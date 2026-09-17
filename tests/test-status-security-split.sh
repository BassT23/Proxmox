#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

LOCAL_FILES="$WORK_DIR"
STATUS_MODEL_FILE="$WORK_DIR/status.json"
STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records"

export LOCAL_FILES STATUS_MODEL_FILE STATUS_MODEL_RECORD_FILE

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

STATUS_MODEL_INIT

# Alpine/APK has only a total update count. A normal count used for
# compatibility must not imply that a security split is available.
STATUS_MODEL_RECORD \
  126 lxc pct true \
  "Alpine Linux v3.24" apk \
  0 false ok "" "" \
  pve-node1 npmplus \
  0 null

# APT genuinely supports separate normal/security counts.
STATUS_MODEL_RECORD \
  127 lxc pct true \
  "Debian GNU/Linux 13" apt \
  0 false ok "" "" \
  pve-node1 debian \
  0 0

# A non-APT updater that explicitly supplies a security count also
# advertises split metadata.
STATUS_MODEL_RECORD \
  128 vm qga true \
  "Example Linux" custom \
  3 false updates_available "" "" \
  pve-node1 example \
  2 1

STATUS_MODEL_FINISH

jq -e '
  .targets[] |
  select(.id == "126") |
  .security_split_supported == false
' "$STATUS_MODEL_FILE" >/dev/null

jq -e '
  .targets[] |
  select(.id == "127") |
  .security_split_supported == true
' "$STATUS_MODEL_FILE" >/dev/null

jq -e '
  .targets[] |
  select(.id == "128") |
  .security_split_supported == true
' "$STATUS_MODEL_FILE" >/dev/null

echo "Status security split regression tests: PASS"
