#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
# Final classification of a cluster update run.
#
# In cluster mode the controller process dispatches per-node runs that record
# their own results (and fail closed when they cannot).  The controller never
# records one itself, so UPDATE_FINAL_RC reported "Update result was not
# recorded; refusing to classify the run as a no-op" and exit 1 after every
# successful cluster run.  A node run that exited 0 or 10 proves a recorded
# result; a run with no node run at all must still fail closed.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^UPDATE_FINAL_RC\(\) \{/{copy=1} copy{print} copy && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/functions.sh"
awk '/^HOST_UPDATE_START \(\) \{/{copy=1} copy{print} copy && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
# update.sh runs without errexit, and UPDATE_HOST returns non-zero on purpose.
set -uo pipefail

WORK_DIR=$1
HOSTS_VALUE=$2
RCS=$3             # space separated exit codes of the per-node runs, in order
LOCAL_FILES="$WORK_DIR/local"
mkdir -p "$LOCAL_FILES"

HOSTS=$HOSTS_VALUE
RICM=false
SSH_PORT=22
USE_INTERNAL_TARGET_SELECTION=false
UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_RESULT_RECORDED=false
SAFETY_FAILURE=false
REMOTE_TARGET_DISPATCHED=false
UPDATE_WARNING_RC=10
read -r -a NODE_RCS <<< "$RCS"
CALL=0

INTERNAL_SSH_RESOLVE_NODE() { INTERNAL_SSH_HOST=$2; INTERNAL_SSH_PORT=$3; INTERNAL_SSH_ENABLED=true; return 0; }
INTERNAL_SSH_USE_IDENTITY() { return 0; }
ssh() { return 0; }
# Node name lookup in corosync.conf: the node name is not under test.
awk() { printf 'node-%s\n' "${2#address=}"; }
UPDATE_HOST() {
  local rc=${NODE_RCS[$CALL]}
  CALL=$((CALL + 1))
  return "$rc"
}

source "$WORK_DIR/functions.sh"
HOST_UPDATE_START
if UPDATE_FINAL_RC 0; then final=0; else final=$?; fi
printf 'final=%s\n' "$final" > "$WORK_DIR/result"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

run_case() {
  local name=$1 hosts=$2 rcs=$3 expected=$4
  mkdir -p "$WORK_DIR/$name"
  cp "$WORK_DIR/functions.sh" "$WORK_DIR/harness.sh" "$WORK_DIR/$name/"
  bash "$WORK_DIR/$name/harness.sh" "$WORK_DIR/$name" "$hosts" "$rcs" > "$WORK_DIR/$name/output" 2>&1 || true
  if ! grep -Fxq "final=$expected" "$WORK_DIR/$name/result"; then
    printf 'case %s: expected final=%s\n' "$name" "$expected" >&2
    cat "$WORK_DIR/$name/result" "$WORK_DIR/$name/output" >&2 || true
    return 1
  fi
}

run_case all-ok "10.9.9.1 10.9.9.2" "0 0" 0
run_case warning-and-ok "10.9.9.1 10.9.9.2" "10 0" 10
run_case warning-only "10.9.9.2" "10" 10
run_case node-failed "10.9.9.1 10.9.9.2" "0 1" 1
run_case failed-only "10.9.9.1" "1" 1
if grep -Fq 'not recorded' "$WORK_DIR/all-ok/output" "$WORK_DIR/warning-only/output"; then
  printf 'a recorded node result must not trigger the fail-closed message\n' >&2
  exit 1
fi

# No node run at all stays fail-closed.
run_case no-node-run "" "" 1
grep -Fq 'Update result was not recorded' "$WORK_DIR/no-node-run/output"

printf '%s\n' 'cluster final result classification regression: PASS'
