#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
JOBS="$WORK_DIR/jobs"
mkdir -p "$JOBS" "$WORK_DIR/bin"

cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:?}"
if [[ "$1" == show ]]; then
  printf 'ActiveState=inactive\nLoadState=loaded\n'
fi
EOF
chmod 750 "$WORK_DIR/bin/systemctl"

unit=ultimate-updater-update-interactive-test
cat > "$JOBS/$unit.state" <<EOF
schema_version=1
unit=$unit
target=900
state=running
started_at=2020-01-01T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
interactive=true
EOF

SYSTEMCTL_LOG="$WORK_DIR/systemctl.log" UU_JOB_STATE_DIR="$JOBS" PATH="$WORK_DIR/bin:$PATH" \
  "$ROOT_DIR/job-runner.sh" cancel "$unit" >"$WORK_DIR/cancel.out"
grep -Fq "stop $unit" "$WORK_DIR/systemctl.log"
grep -Eq '^state=cancelled$' "$JOBS/$unit.state"
grep -Eq '^exit_code=130$' "$JOBS/$unit.state"
grep -Fq 'Job cancelled by user.' "$JOBS/$unit.state"
grep -Eq '^interactive=true$' "$JOBS/$unit.state"
[[ ! -e "$JOBS/$unit.cancel" ]]

if SYSTEMCTL_LOG="$WORK_DIR/systemctl.log" UU_JOB_STATE_DIR="$JOBS" PATH="$WORK_DIR/bin:$PATH" \
  "$ROOT_DIR/job-runner.sh" cancel "$unit" >/dev/null 2>&1; then
  echo 'repeated cancellation unexpectedly returned success' >&2
  exit 1
fi
if SYSTEMCTL_LOG="$WORK_DIR/systemctl.log" UU_JOB_STATE_DIR="$JOBS" PATH="$WORK_DIR/bin:$PATH" \
  "$ROOT_DIR/job-runner.sh" cancel 'ultimate-updater-update-x;touch-pwned' >/dev/null 2>&1; then
  echo 'invalid job ID unexpectedly accepted' >&2
  exit 1
fi

# Simulate systemd having terminated the runner before its normal finalizer.
# The cancel request itself must publish the authoritative state.
SYSTEMCTL_LOG="$WORK_DIR/systemctl.log" UU_JOB_STATE_DIR="$JOBS" PATH="$WORK_DIR/bin:$PATH" \
  "$ROOT_DIR/job-runner.sh" list >/dev/null
grep -Eq '^state=cancelled$' "$JOBS/$unit.state"
grep -Eq '^exit_code=130$' "$JOBS/$unit.state"
grep -Fq 'Job cancelled by user.' "$JOBS/$unit.state"
[[ ! -e "$JOBS/$unit.cancel" ]]

cat > "$JOBS/ultimate-updater-update-finished.state" <<'EOF'
schema_version=1
unit=ultimate-updater-update-finished
target=900
state=completed
started_at=2020-01-01T00:00:00Z
finished_at=2020-01-01T00:00:01Z
exit_code=0
type=update
message=
interactive=true
EOF
if SYSTEMCTL_LOG="$WORK_DIR/systemctl.log" UU_JOB_STATE_DIR="$JOBS" PATH="$WORK_DIR/bin:$PATH" \
  "$ROOT_DIR/job-runner.sh" cancel ultimate-updater-update-finished >/dev/null 2>&1; then
  echo 'finished job unexpectedly cancellable' >&2
  exit 1
fi

echo 'job cancellation state and unit-safety tests: PASS'
