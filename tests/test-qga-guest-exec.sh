#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/qm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 ${2:-}" == 'guest exec-status' ]]; then
  status_count=$(grep -c '^status$' "$QGA_CALLS" 2>/dev/null || true)
  if [[ "$QGA_STATUS_RESPONSE" == '{"exited":false}' && "$status_count" -gt 0 ]]; then
    printf '%s\n' '{"exited":true,"exitcode":0}'
  else
    printf '%s\n' "$QGA_STATUS_RESPONSE"
  fi
  printf '%s\n' status >> "$QGA_CALLS"
else
  printf '%s\n' exec >> "$QGA_CALLS"
  printf '%s\n' "$QGA_EXEC_RESPONSE"
fi
MOCK
chmod 750 "$WORK_DIR/qm"

source "$ROOT_DIR/qga-guest-exec.sh"
export PATH="$WORK_DIR:$PATH"
export QGA_CALLS="$WORK_DIR/calls"

run_case() {
  : > "$QGA_CALLS"
  local status_response="${2:-'{"exited":true,"exitcode":0}'}"
  QGA_EXEC_RESPONSE="$1" QGA_STATUS_RESPONSE="$status_response" \
    QEMU_GUEST_EXEC 310 --timeout 5 -- /bin/true
}

run_case '{"pid":1234}' '{"exited":true,"exitcode":0,"out-data":"out\n","err-data":"err\n"}'
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]
[[ "$QEMU_EXEC_STDOUT" == $'out\n' && "$QEMU_EXEC_STDERR" == $'err\n' ]]
[[ $(grep -c '^status$' "$QGA_CALLS") == 1 ]]

# A remote wrapper/banner before the JSON must not corrupt the PID.
run_case $'remote wrapper\n{"pid":42}' '{"exited":true,"exitcode":0}'
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]
[[ $(grep -c '^status$' "$QGA_CALLS") == 1 ]]

# Invalid PID responses fail before guest-exec-status is ever called.
for invalid in \
  '{}' '{"pid":null}' '{"pid":""}' '{"pid":"abc"}' \
  '{"pid":false}' '{"pid":0}' '{"pid":-1}' ''; do
  : > "$QGA_CALLS"
  run_case "$invalid" || true
  [[ "$QEMU_EXEC_ERROR_CLASS" == QGA_INVALID_PID ]]
  [[ "$QEMU_EXEC_TRANSPORT_RC" == 1 ]]
  [[ $(grep -c '^status$' "$QGA_CALLS" || true) == 0 ]]
done

# Long-running commands are polled until exited, and guest failures remain
# guest exit codes rather than transport failures.
: > "$QGA_CALLS"
export QGA_EXEC_RESPONSE='{"pid":9}'
export QGA_STATUS_RESPONSE='{"exited":0}'
QEMU_GUEST_EXEC 310 --timeout 5 -- /bin/true
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]

export QGA_EXEC_RESPONSE='{"pid":9}'
export QGA_STATUS_RESPONSE='{"exited":true,"exitcode":42,"err-data":"failed\n"}'
QEMU_GUEST_EXEC 310 --timeout 5 -- /bin/true
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 42 ]]
[[ "$QEMU_EXEC_STDERR" == $'failed\n' ]]

# Both production paths use the same helper and keep the two APT commands in
# their ordinary QGA execution path.
grep -Fq 'source "$QGA_EXEC_SCRIPT"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'source "$QGA_EXEC_SCRIPT"' "$ROOT_DIR/update.sh"
grep -Fq 'apt-get update' "$ROOT_DIR/update.sh"
grep -Fq 'apt-get' "$ROOT_DIR/update.sh"

echo 'QGA guest-exec PID/status contract tests: PASS'
