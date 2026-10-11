#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

JOBS="$WORK_DIR/jobs"
LOCAL="$WORK_DIR/local"
mkdir -p "$JOBS" "$LOCAL/temp" "$WORK_DIR/bin"

cat > "$WORK_DIR/timeout-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
marker="${UU_LOCAL_FILES}/temp/windows-update-unresolved"
mkdir -p "$(dirname "$marker")"
printf 'job_id=uu-test-long-running\ntarget=986\nreason=controller-timeout\n' > "$marker"
exit 75
EOF
chmod +x "$WORK_DIR/timeout-update.sh"

cat > "$WORK_DIR/recover-update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${UU_WINDOWS_STATUS_ONLY_JOB_ID:-}" == uu-test-long-running ]]
[[ "${UU_WINDOWS_STATUS_ONLY_VM:-}" == 986 ]]
exit 0
EOF
chmod +x "$WORK_DIR/recover-update.sh"

unit=ultimate-updater-update-986-long-running
cat > "$JOBS/$unit.state" <<EOF
schema_version=1
unit=$unit
target=986
state=running
started_at=2026-10-11T00:00:00Z
finished_at=
exit_code=
type=update
message=
source=
interactive=false
EOF

UU_JOB_STATE_DIR="$JOBS" UU_LOCAL_FILES="$LOCAL" \
  "$ROOT_DIR/job-runner.sh" run "$unit" 986 "$WORK_DIR/timeout-update.sh" \
  >"$WORK_DIR/timeout.out" 2>&1

grep -Fxq 'state=unresolved' "$JOBS/$unit.state"
grep -Fq 'remains active or unknown' "$JOBS/$unit.state"
test ! -e "$LOCAL/temp/windows-update-unresolved"

# An unresolved guest job remains a target conflict and cannot be replaced by
# a new controller start. This protects against a second Windows installation
# after the controller deadline. Starting jobs requires root, so keep the
# fixture useful in unprivileged CI as well.
if [[ "$EUID" -eq 0 ]]; then
  cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$WORK_DIR/bin/systemd-run"
  if UU_JOB_STATE_DIR="$JOBS" UU_LOCAL_FILES="$LOCAL" PATH="$WORK_DIR/bin:$PATH" \
    "$ROOT_DIR/job-runner.sh" start "$WORK_DIR/timeout-update.sh" 986 >"$WORK_DIR/conflict.out" 2>&1; then
    echo 'unresolved Windows job was incorrectly replaceable' >&2
    exit 1
  fi
  grep -Fq 'A job is already running for target 986' "$WORK_DIR/conflict.out" || {
    cat "$WORK_DIR/conflict.out" >&2
    exit 1
  }
fi

set +e
UU_JOB_STATE_DIR="$JOBS" UU_LOCAL_FILES="$LOCAL" \
  "$ROOT_DIR/job-runner.sh" recover-local "$unit" 986 "$WORK_DIR/recover-update.sh"
recover_rc=$?
set -e
if [[ "$recover_rc" -ne 0 ]]; then
  cat "$JOBS/$unit.state" >&2
  exit 1
fi
grep -Fxq 'state=completed' "$JOBS/$unit.state" || { cat "$JOBS/$unit.state" >&2; exit 1; }
grep -Fxq 'exit_code=0' "$JOBS/$unit.state" || { cat "$JOBS/$unit.state" >&2; exit 1; }
grep -Fq 'recovered from controller timeout' "$JOBS/$unit.state" || { cat "$JOBS/$unit.state" >&2; exit 1; }

echo 'Windows long-running job lifecycle: PASS'
