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

# A compatibility normal count alone is not split metadata.
STATUS_MODEL_RECORD \
  129 lxc pct true \
  "Alpine Linux v3.24" apk \
  5 false updates_available "" "" \
  pve-node1 alpine-five \
  5 null

# The same total-only semantics apply to generic/custom updaters.
STATUS_MODEL_RECORD \
  130 vm qga true \
  "Example Linux" custom \
  3 false updates_available "" "" \
  pve-node1 custom-total \
  3 null

# A present security count, including zero, is known split metadata.
STATUS_MODEL_RECORD \
  131 vm qga true \
  "Example Linux" custom \
  1 false updates_available "" "" \
  pve-node1 custom-security-only \
  null 1

STATUS_MODEL_RECORD \
  132 vm qga true \
  "Example Linux" custom \
  0 false ok "" "" \
  pve-node1 custom-unknown \
  null null

STATUS_MODEL_RECORD \
  133 vm qga true \
  "Example Linux" custom \
  0 false ok "" "" \
  pve-node1 custom-zero-security \
  0 0

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

jq -e '
  [.targets[] | select(.id == "129")][0].security_split_supported == false and
  [.targets[] | select(.id == "130")][0].security_split_supported == false and
  [.targets[] | select(.id == "131")][0].security_split_supported == true and
  [.targets[] | select(.id == "132")][0].security_split_supported == false and
  [.targets[] | select(.id == "133")][0].security_split_supported == true
' "$STATUS_MODEL_FILE" >/dev/null

# Explicit capability metadata remains authoritative over inferred defaults.
cat > "$WORK_DIR/explicit-capability.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"explicit-true","type":"vm","updater":"custom","updates":{"available":1},"normal_updates":null,"security_updates":null,"security_split_supported":true},
  {"id":"explicit-false","type":"vm","updater":"apt","updates":{"available":1},"normal_updates":1,"security_updates":0,"security_split_supported":false}
]}
JSON

STATUS_MODEL_FILE="$WORK_DIR/explicit-capability-status.json" \
STATUS_MODEL_RECORD_FILE="$WORK_DIR/explicit-capability.records" \
  bash -c '
    . "$1/status-model.sh"
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR" "$WORK_DIR/explicit-capability.json"

jq -e '
  [.targets[] | select(.id == "explicit-true")][0].security_split_supported == true and
  [.targets[] | select(.id == "explicit-false")][0].security_split_supported == false
' "$WORK_DIR/explicit-capability-status.json" >/dev/null

echo "Status security split regression tests: PASS"
