#!/bin/bash
# The temporary runner copy bypasses only the real-root prerequisite of this harness.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs"
awk '/Starting check jobs requires root/ { print "  :"; next } { print }' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/job-runner.sh"
chmod 750 "$WORK_DIR/job-runner.sh"
cat > "$WORK_DIR/bin/systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$SYSTEMD_ARGS_FILE"
printf 'Running as unit: test-unit\n'
SH
chmod 750 "$WORK_DIR/bin/systemd-run"
printf '#!/bin/bash\nexit 0\n' > "$WORK_DIR/check-cli"
chmod 750 "$WORK_DIR/check-cli"

run_start_check() {
  local value=${1-} args_file="$WORK_DIR/systemd-${2}.args"
  : > "$args_file"
  if [[ "$2" == unset ]]; then
    env -u UU_REMOTE_TRACE SYSTEMD_ARGS_FILE="$args_file" UU_JOB_STATE_DIR="$WORK_DIR/jobs-$2" \
      PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/job-runner.sh" \
      start-check all-systems "$WORK_DIR/check-cli" all >/dev/null
  else
    SYSTEMD_ARGS_FILE="$args_file" UU_REMOTE_TRACE="$value" UU_JOB_STATE_DIR="$WORK_DIR/jobs-$2" \
      PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/job-runner.sh" \
      start-check all-systems "$WORK_DIR/check-cli" all >/dev/null
  fi
}

run_start_check '' unset
if grep -Fq -- '--setenv=UU_REMOTE_TRACE=' "$WORK_DIR/systemd-unset.args"; then exit 1; fi

run_start_check false false
if grep -Fq -- '--setenv=UU_REMOTE_TRACE=' "$WORK_DIR/systemd-false.args"; then exit 1; fi

run_start_check true true
grep -Fq -- '--setenv=UU_REMOTE_TRACE=true' "$WORK_DIR/systemd-true.args"
if grep -Fq -- '--setenv=UU_REMOTE_TRACE=false' "$WORK_DIR/systemd-true.args"; then exit 1; fi
if grep -Fq -- '--setenv=UU_SINGLE_TARGET' "$WORK_DIR/systemd-true.args" ||
  grep -Fq -- '--setenv=UU_JOB_SOURCE' "$WORK_DIR/systemd-true.args"; then
  exit 1
fi

printf '%s\n' 'job-runner trace propagation tests: PASS'
