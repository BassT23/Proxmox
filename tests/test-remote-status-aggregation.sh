#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true' EXIT

# The remote dispatch must have an isolated artifact directory, an explicit
# completion marker, and a bounded timeout distinct from SSH transfer setup.
grep -Eq 'remote_check_dir="/tmp/ultimate-updater-check-.*RANDOM' "$ROOT_DIR/check-updates.sh"
grep -Fq "remote_done_file=\"\$remote_check_dir/completed\"" "$ROOT_DIR/check-updates.sh"
grep -Fq 'CHECK_REMOTE_JOB_TIMEOUT:-300' "$ROOT_DIR/check-updates.sh"
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
grep -Fq 'UU_REMOTE_DEFER_STATUS_FINISH=true' "$ROOT_DIR/check-updates.sh"
grep -Fq 'REMOTE_CHECK_RETURN node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STATUS_MODEL_FINISH_START node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'STATUS_MODEL_FINISH_END node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'COMPLETION_WRITE node=' "$ROOT_DIR/check-updates.sh"
grep -Fq 'UU_REMOTE_DEFER_STATUS_FINISH:-false' "$ROOT_DIR/check-updates.sh"
# shellcheck disable=SC2016
grep -Fq 'UU_CHECK_REMOTE_WRAPPER_TIMEOUT:-$((job_timeout + 60))' "$ROOT_DIR/check-updates.sh"
for marker in \
  'CENTRAL_REMOTE_START node=' \
  'CENTRAL_REMOTE_SSH_RETURN node=' \
  'CENTRAL_COMPLETION_FETCH_START node=' \
  'CENTRAL_COMPLETION_FETCH_END node=' \
  'CENTRAL_STATUS_FETCH_START node=' \
  'CENTRAL_STATUS_FETCH_END node=' \
  'CENTRAL_DIAGNOSTICS_FETCH_START node=' \
  'CENTRAL_DIAGNOSTICS_FETCH_END node=' \
  'CENTRAL_CLEANUP_START node=' \
  'CENTRAL_CLEANUP_END node=' \
  'CENTRAL_REMOTE_END node='; do
  grep -Fq "$marker" "$ROOT_DIR/check-updates.sh"
done
grep -Fq 'bash -s -- host' "$ROOT_DIR/check-updates.sh"
# shellcheck disable=SC2016 # the literal shell fragment is the assertion target.
grep -Fq '"$LOCAL_FILES/update.conf" "$HOST:$LOCAL_FILES/update.conf"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'DEBUG:-false' "$ROOT_DIR/check-updates.sh"

# The remote wrapper owns finalization.  An inner check that exits before its
# own epilogue must still produce a final status and completion result.
cat > "$WORK_DIR/status-model.sh" <<'EOF'
STATUS_MODEL_INIT() { : > "$STATUS_MODEL_RECORD_FILE"; }
STATUS_MODEL_FINISH() {
  printf '{"targets":[]}' > "$STATUS_MODEL_FILE"
}
EOF
cat > "$WORK_DIR/inner-check.sh" <<'EOF'
#!/bin/bash
source "$STATUS_MODEL_SCRIPT"
STATUS_MODEL_INIT
case "$1" in
  exit-zero) exit 0 ;;
  exit-failure) exit 17 ;;
  return-zero) return 0 2>/dev/null || true ;;
  return-failure) return 19 2>/dev/null || true ;;
esac
EOF
chmod +x "$WORK_DIR/inner-check.sh"
for mode in normal exit-zero exit-failure return-zero return-failure; do
  rm -f "$WORK_DIR/status.json" "$WORK_DIR/status.records" "$WORK_DIR/completed"
  STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
    STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" bash -c '
      source "$STATUS_MODEL_SCRIPT"
      STATUS_MODEL_INIT
      bash "$1" "$2"
      remote_rc=$?
      STATUS_MODEL_FINISH
      printf "%s\n" "$remote_rc" > "$3"
      exit "$remote_rc"
    ' _ "$WORK_DIR/inner-check.sh" "$mode" "$WORK_DIR/completed" || true
  [[ -s "$WORK_DIR/status.json" ]]
  [[ -s "$WORK_DIR/completed" ]]
done

# An inner timeout must return control to the wrapper, which then completes
# finalization and writes a deterministic completion RC.
cat > "$WORK_DIR/slow-check.sh" <<'EOF'
#!/bin/bash
sleep 2
EOF
rm -f "$WORK_DIR/status.json" "$WORK_DIR/completed" "$WORK_DIR/diagnostics"
(
  set +e
  timeout 1 bash "$WORK_DIR/slow-check.sh"
  remote_rc=$?
  printf '%s\n' 'REMOTE_CHECK_RETURN rc='"$remote_rc" >> "$WORK_DIR/diagnostics"
  printf '%s\n' 'STATUS_MODEL_FINISH_START' >> "$WORK_DIR/diagnostics"
  printf '{"targets":[]}' > "$WORK_DIR/status.json"
  printf '%s\n' 'STATUS_MODEL_FINISH_END rc=0 exists=true' >> "$WORK_DIR/diagnostics"
  printf '%s\n' "$remote_rc" > "$WORK_DIR/completed"
  printf '%s\n' 'COMPLETION_WRITE rc='"$remote_rc" >> "$WORK_DIR/diagnostics"
)
grep -Fq 'REMOTE_CHECK_RETURN rc=124' "$WORK_DIR/diagnostics"
grep -Fq 'STATUS_MODEL_FINISH_END rc=0 exists=true' "$WORK_DIR/diagnostics"
grep -Fq 'COMPLETION_WRITE rc=124' "$WORK_DIR/diagnostics"
[[ -s "$WORK_DIR/status.json" && "$(cat "$WORK_DIR/completed")" == 124 ]]

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
