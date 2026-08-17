#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true' EXIT

# The remote dispatch must have an isolated artifact directory, an explicit
# completion marker, and a bounded timeout distinct from SSH transfer setup.
grep -Eq 'remote_check_dir="/tmp/ultimate-updater-check-.*RANDOM' "$ROOT_DIR/check-updates.sh"
grep -Fq "remote_done_file=\"\$remote_check_dir/completed\"" "$ROOT_DIR/check-updates.sh"
grep -Fq 'CHECK_REMOTE_JOB_TIMEOUT:-120' "$ROOT_DIR/check-updates.sh"
grep -Fq 'remote check completed but status result could not be retrieved' "$ROOT_DIR/check-updates.sh"

# A failed remote node must not discard successful records from other nodes.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" bash -c '
  source "$1"
  STATUS_MODEL_INIT
  STATUS_MODEL_RECORD "host:node1" host ssh true "" "" null null ok
  STATUS_MODEL_RECORD "host:node3" host ssh true "" "" null null error REMOTE_STATUS_IMPORT_FAILED "node3 status missing" node3
  STATUS_MODEL_FINISH
' _ "$ROOT_DIR/status-model.sh"
grep -Fq '"id": "host:node1"' "$WORK_DIR/status.json"
grep -Fq '"id": "host:node3"' "$WORK_DIR/status.json"
grep -Fq 'REMOTE_STATUS_IMPORT_FAILED' "$WORK_DIR/status.json"

printf '%s\n' 'remote status aggregation regression tests: PASS'
