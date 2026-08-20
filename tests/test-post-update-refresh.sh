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
mkdir -p "$WORK_DIR/jobs"

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

echo 'post-update status refresh tests: PASS'
