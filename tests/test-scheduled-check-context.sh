#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs"
awk '/Starting check jobs requires root/ { print "  :"; next } { print }' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/job-runner.sh"
chmod 750 "$WORK_DIR/job-runner.sh"
cat > "$WORK_DIR/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${SYSTEMD_ARGS_FILE:?}"
printf 'Running as unit: test-unit\n'
SH
chmod 750 "$WORK_DIR/bin/systemd-run"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_DIR/check-cli"
chmod 750 "$WORK_DIR/check-cli"

run_context() {
  local source="$1" expected_source="$2" args_file="$WORK_DIR/$1.args"
  : > "$args_file"
  SYSTEMD_ARGS_FILE="$args_file" \
    UU_JOB_STATE_DIR="$WORK_DIR/jobs-$source" \
    UU_JOB_SOURCE="$source" UU_SCHEDULED_CHECK=true UU_NONINTERACTIVE=true \
    UU_HEARTBEAT_URL_FILE="$WORK_DIR/heartbeat-url" \
    UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/heartbeat-token" \
    UU_HEARTBEAT_STATE_FILE="$WORK_DIR/heartbeat-state" \
    PATH="$WORK_DIR/bin:$PATH" \
    bash "$WORK_DIR/job-runner.sh" start-check all-systems "$WORK_DIR/check-cli" all >/dev/null
  grep -Fq -- "--setenv=UU_JOB_SOURCE=$expected_source" "$args_file"
  grep -Fq -- '--setenv=UU_SCHEDULED_CHECK=true' "$args_file"
  grep -Fq -- '--setenv=UU_NONINTERACTIVE=true' "$args_file"
  grep -Fq -- "--setenv=UU_HEARTBEAT_URL_FILE=$WORK_DIR/heartbeat-url" "$args_file"
  grep -Fq -- "--setenv=UU_HEARTBEAT_TOKEN_FILE=$WORK_DIR/heartbeat-token" "$args_file"
  grep -Fq -- "--setenv=UU_HEARTBEAT_STATE_FILE=$WORK_DIR/heartbeat-state" "$args_file"
}

run_context initial-inventory initial-inventory
run_context scheduler scheduler

printf '%s\n' 'scheduled check context propagation tests: PASS'
