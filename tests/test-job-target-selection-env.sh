#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ "$EUID" -ne 0 ]]; then
  echo 'job target-selection environment propagation tests: SKIP (root required)'
  exit 0
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs" "$WORK_DIR/runtime"
cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$UU_SYSTEMD_ARGS"
exit 0
EOF
chmod +x "$WORK_DIR/bin/systemd-run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_DIR/runtime/update.sh"
chmod +x "$WORK_DIR/runtime/update.sh"

run_start() {
  rm -f "$WORK_DIR/jobs"/*.state
  : > "$WORK_DIR/systemd.args"
  UU_SYSTEMD_ARGS="$WORK_DIR/systemd.args" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
    PATH="$WORK_DIR/bin:$PATH" "$@" "$ROOT_DIR/job-runner.sh" start \
    "$WORK_DIR/runtime/update.sh" target
}

run_start env -u UU_TARGET_SELECTION_FILE
if grep -Fq -- '--setenv=UU_TARGET_SELECTION_FILE=' "$WORK_DIR/systemd.args"; then
  exit 1
fi

run_start env UU_TARGET_SELECTION_FILE=/tmp/safe-selection-fixture.json
grep -Fq -- '--setenv=UU_TARGET_SELECTION_FILE=/tmp/safe-selection-fixture.json' "$WORK_DIR/systemd.args"

run_start env UU_TARGET_SELECTION_FILE=
if grep -Fq -- '--setenv=UU_TARGET_SELECTION_FILE=' "$WORK_DIR/systemd.args"; then
  exit 1
fi

echo 'job target-selection environment propagation tests: PASS'
