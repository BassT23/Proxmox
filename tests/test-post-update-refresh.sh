#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
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
chmod +x "$WORK_DIR/update.sh" "$WORK_DIR/check.sh"

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
  "$ROOT_DIR/job-runner.sh" run "$unit" host "$WORK_DIR/update.sh" >/dev/null

grep -Fq 'UPDATE_TARGET=host' "$WORK_DIR/log"
grep -Fq 'CHECK_SCOPE=host CHECK_ARGS=host' "$WORK_DIR/log"
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
