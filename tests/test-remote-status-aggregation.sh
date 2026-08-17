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

# Retrieval failures must leave a correlation trail in the job log while
# successful runs remain quiet unless DEBUG is enabled.
grep -Fq 'REMOTE_STATUS_DIAGNOSTICS' "$ROOT_DIR/check-updates.sh"
grep -Fq 'completion_found=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'status_found=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'cleanup=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'classification=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'completion-marker-missing' "$ROOT_DIR/check-updates.sh"
grep -Fq 'status-file-missing' "$ROOT_DIR/check-updates.sh"
grep -Fq 'ssh-retrieval-failed' "$ROOT_DIR/check-updates.sh"
grep -Fq 'scp-retrieval-failed' "$ROOT_DIR/check-updates.sh"
grep -Fq 'permission-denied' "$ROOT_DIR/check-updates.sh"
grep -Fq 'invalid-json' "$ROOT_DIR/check-updates.sh"
grep -Fq 'remote-rc-nonzero' "$ROOT_DIR/check-updates.sh"
grep -Fq 'timeout' "$ROOT_DIR/check-updates.sh"
grep -Fq 'remote_status_validation=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'remote_rc=86' "$ROOT_DIR/check-updates.sh"
grep -Fq 'remote_rc=87' "$ROOT_DIR/check-updates.sh"
grep -Fq 'status_finish_rc=0' "$ROOT_DIR/check-updates.sh"
grep -Fq 'CHECK_FAILURE=1' "$ROOT_DIR/check-updates.sh"
grep -Fq 'status-file-missing-after-finalization' "$ROOT_DIR/check-updates.sh"
grep -Fq 'invalid-json-after-finalization' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STATUS_MODEL_INIT node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STATUS_MODEL_FINISH node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STATUS_MODEL_DIAGNOSTICS_FILE' "$ROOT_DIR/check-updates.sh"
grep -Fq 'Remote status model: node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'Remote status model diagnostics unavailable:' "$ROOT_DIR/check-updates.sh"
grep -Fq 'status-diagnostics' "$ROOT_DIR/check-updates.sh"

# An absent completion marker must not be relabelled as a remote RC failure;
# the marker is the only authoritative source for the remote RC.
grep -Fq "if [[ \"\$remote_done_found\" == true && \"\$remote_status\" -ne 0 ]]" "$ROOT_DIR/check-updates.sh"

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
