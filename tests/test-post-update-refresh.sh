#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# shellcheck disable=SC2016 # literal shell fragments are assertion targets.
grep -Fq 'refresh_remote_target_status "$unit" "$owner_node" "$remote_target"' "$ROOT_DIR/job-runner.sh"
# shellcheck disable=SC2016 # literal shell fragments are assertion targets.
grep -Fq '"$CHECK_CLI" check-node "$owner_node"' "$ROOT_DIR/job-runner.sh"
grep -Fq 'status_refresh=pending' "$ROOT_DIR/job-runner.sh"
grep -Fq 'function isStatusRefreshJob(job)' "$ROOT_DIR/web-ui/server.py"
grep -Fq 'if(statusRefreshJobFinished)await loadStatus()' "$ROOT_DIR/web-ui/server.py"
grep -Fq 'self.jobs()' "$ROOT_DIR/web-ui/server.py"
grep -Fq 'refresh_remote_jobs' "$ROOT_DIR/ultimate-updater"
mkdir -p "$WORK_DIR/jobs"

# Reading central status must give the remote-job reconciler an opportunity to
# import a completed remote capture before the old status is returned.
cat > "$WORK_DIR/job-runner.sh" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == list ]]
printf 'refresh-called\n' >> "$REFRESH_CALLS"
EOF
chmod +x "$WORK_DIR/job-runner.sh"
printf '{"targets":[]}\n' > "$WORK_DIR/status.json"
REFRESH_CALLS="$WORK_DIR/refresh-calls" UU_LOCAL_FILES="$WORK_DIR" \
  "$ROOT_DIR/ultimate-updater" status --json > "$WORK_DIR/status-output"
grep -Fxq 'refresh-called' "$WORK_DIR/refresh-calls"
grep -Fq '"targets"' "$WORK_DIR/status-output"

cat > "$WORK_DIR/update.sh" <<'EOF'
#!/usr/bin/env bash
printf 'UPDATE_TARGET=%s\n' "$1" >> "$POST_REFRESH_LOG"
exit 0
EOF
cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
printf 'CHECK_SCOPE=%s CHECK_ARGS=%s\n' "${UU_CHECK_SCOPE:-}" "$*" >> "$POST_REFRESH_LOG"
exit "${POST_CHECK_RC:-0}"
EOF
cat > "$WORK_DIR/status-model.sh" <<'EOF'
#!/usr/bin/env bash
STATUS_MODEL_SEND_UPDATE_NOTIFICATION() {
  printf 'NOTIFICATION_AFTER_REFRESH\n' >> "$POST_REFRESH_LOG"
}
EOF
printf '{}\n' > "$WORK_DIR/status.json"
printf 'EMAIL_USER="root"\n' > "$WORK_DIR/update.conf"
chmod +x "$WORK_DIR/update.sh" "$WORK_DIR/check.sh" "$WORK_DIR/status-model.sh"

unit=ultimate-updater-update-host-test
cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=host
state=running
started_at=2026-08-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
EOF

POST_REFRESH_LOG="$WORK_DIR/log" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_CHECK_SCRIPT="$WORK_DIR/check.sh" UU_UPDATE_SCOPE=host \
  UU_STATUS_MODEL_SCRIPT="$WORK_DIR/status-model.sh" UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
  "$ROOT_DIR/job-runner.sh" run "$unit" host "$WORK_DIR/update.sh" >/dev/null

grep -Fq 'UPDATE_TARGET=host' "$WORK_DIR/log"
grep -Fq 'CHECK_SCOPE=host CHECK_ARGS=host' "$WORK_DIR/log"
test "$(sed -n '1p' "$WORK_DIR/log")" = 'UPDATE_TARGET=host'
test "$(sed -n '2p' "$WORK_DIR/log")" = 'CHECK_SCOPE=host CHECK_ARGS=host'
test "$(sed -n '3p' "$WORK_DIR/log")" = 'NOTIFICATION_AFTER_REFRESH'
grep -Eq '^state=completed$' "$WORK_DIR/jobs/$unit.state"
grep -Eq '^exit_code=0$' "$WORK_DIR/jobs/$unit.state"
grep -Fq 'post-update host status refresh rc=0' "$WORK_DIR/jobs/$unit.state"

rm -f "$WORK_DIR/log"
unit=ultimate-updater-update-host-failed-refresh
cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=host
state=running
started_at=2026-08-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
EOF
POST_REFRESH_LOG="$WORK_DIR/log" POST_CHECK_RC=17 UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_CHECK_SCRIPT="$WORK_DIR/check.sh" UU_UPDATE_SCOPE=host \
  "$ROOT_DIR/job-runner.sh" run "$unit" host "$WORK_DIR/update.sh" >/dev/null
grep -Eq '^state=completed$' "$WORK_DIR/jobs/$unit.state"
grep -Eq '^exit_code=0$' "$WORK_DIR/jobs/$unit.state"
grep -Fq 'post-update host status refresh rc=17' "$WORK_DIR/jobs/$unit.state"

unit=ultimate-updater-update-all-systems-test
cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=all-systems
state=running
started_at=2026-08-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
EOF
POST_REFRESH_LOG="$WORK_DIR/log" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_CHECK_CLI="$WORK_DIR/check.sh" \
  "$ROOT_DIR/job-runner.sh" run-global "$unit" "$WORK_DIR/update.sh" >/dev/null
grep -Fq 'CHECK_SCOPE= CHECK_ARGS=check' "$WORK_DIR/log"
grep -Eq '^state=completed$' "$WORK_DIR/jobs/$unit.state"
grep -Eq '^exit_code=0$' "$WORK_DIR/jobs/$unit.state"
grep -Fq 'post-update full status refresh rc=0' "$WORK_DIR/jobs/$unit.state"

# A guest update must consume the status captured before lifecycle restore.
# It must not start a second normal check after the guest is stopped.
rm -f "$WORK_DIR/log"
cat > "$WORK_DIR/update-guest.sh" <<'EOF'
#!/usr/bin/env bash
printf 'UPDATE_TARGET=%s\n' "$1" >> "$POST_REFRESH_LOG"
printf '0\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
exit 0
EOF
chmod +x "$WORK_DIR/update-guest.sh"
unit=ultimate-updater-update-191-captured
cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=191
state=running
started_at=2026-08-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
EOF
POST_REFRESH_LOG="$WORK_DIR/log" UU_REMOTE_WORK_DIR="$WORK_DIR" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_CHECK_CLI="$WORK_DIR/check.sh" UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
  "$ROOT_DIR/job-runner.sh" run "$unit" 191 "$WORK_DIR/update-guest.sh" >/dev/null
grep -Fq 'post-update target status captured before lifecycle restore rc=0' "$WORK_DIR/jobs/$unit.state"
if grep -Fq 'CHECK_SCOPE=' "$WORK_DIR/log"; then
  exit 1
fi
if grep -Fq 'Post-update status refresh started' "$WORK_DIR/log"; then
  exit 1
fi

# A semantic capture failure must be visible as a capture failure, without
# changing the successful package-update result or starting a second check.
cat > "$WORK_DIR/update-guest-not-checked.sh" <<'EOF'
#!/usr/bin/env bash
printf '89\n' > "$UU_REMOTE_WORK_DIR/post-update-status.rc"
exit 0
EOF
chmod +x "$WORK_DIR/update-guest-not-checked.sh"
unit=ultimate-updater-update-191-not-checked
cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=191
state=running
started_at=2026-08-18T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
EOF
POST_REFRESH_LOG="$WORK_DIR/log" UU_REMOTE_WORK_DIR="$WORK_DIR" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_CHECK_CLI="$WORK_DIR/check.sh" UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
  "$ROOT_DIR/job-runner.sh" run "$unit" 191 "$WORK_DIR/update-guest-not-checked.sh" >"$WORK_DIR/not-checked-output" 2>&1
grep -Fq 'Post-update status capture failed for 191: POST_UPDATE_CAPTURE_NOT_CHECKED' "$WORK_DIR/not-checked-output"
if grep -Fq 'Post-update status captured before lifecycle restore for 191.' "$WORK_DIR/not-checked-output"; then
  exit 1
fi
grep -Eq '^state=completed$' "$WORK_DIR/jobs/$unit.state"
grep -Fq 'POST_UPDATE_CAPTURE_NOT_CHECKED' "$WORK_DIR/jobs/$unit.state"

grep -Fq 'Continue after errors: enabled' "$ROOT_DIR/update.sh"
grep -Fq 'Continue after errors: disabled' "$ROOT_DIR/update.sh"
if grep -Fq 'work only on main host' "$ROOT_DIR/update.sh"; then
  exit 1
fi

echo 'post-update status refresh tests: PASS'
