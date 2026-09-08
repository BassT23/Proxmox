#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2218
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/qm" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 ${2:-}" == 'guest exec-status' ]]; then
  status_count=$(grep -c '^status$' "$QGA_CALLS" 2>/dev/null || true)
  printf '%s\n' status >> "$QGA_CALLS"
  if [[ "$QGA_STATUS_RESPONSE" == '{"exited":0}' && "$status_count" -gt 0 ]]; then
    printf '%s\n' '{"exited":true,"exitcode":0}'
  else
    printf '%s\n' "$QGA_STATUS_RESPONSE"
  fi
else
  printf '%s\n' exec >> "$QGA_CALLS"
  printf '%s\n' "$QGA_EXEC_RESPONSE"
fi
MOCK
chmod 750 "$WORK_DIR/qm"

source "$ROOT_DIR/qga-guest-exec.sh"
export PATH="$WORK_DIR:$PATH"
export QGA_CALLS="$WORK_DIR/calls"

# A reachable agent can reject only guest-exec.  Keep that capability error
# distinct from a transport/readiness failure for both check and update paths.
QEMU_EXEC_OUTPUT='Agent error: Command guest-exec has been disabled: the command is not allowed'
QGA_GUEST_EXEC_DISABLED
QEMU_EXEC_OUTPUT='Agent error: guest command failed'
if QGA_GUEST_EXEC_DISABLED; then
  echo 'generic guest-exec failure was classified as disabled' >&2
  exit 1
fi
grep -Fq 'error QGA_GUEST_EXEC_DISABLED' "$ROOT_DIR/check-updates.sh"
grep -Fq 'QGA_GUEST_EXEC_DISABLED' "$ROOT_DIR/update.sh"

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

# A lost QGA PID after the detached job was started must only cause a retry of
# the durable status read, never a second guest update start.
durable_calls="$WORK_DIR/durable-calls"
durable_call_count=0
QEMU_GUEST_EXEC() {
  durable_call_count=$((durable_call_count + 1))
  printf '%s\n' "$*" >> "$durable_calls"
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_ERROR_CLASS=""
  case "$durable_call_count" in
    1) return 0 ;; # launch accepted
    2)
      QEMU_EXEC_ERROR_CLASS=QGA_INVALID_PID
      QEMU_EXEC_OUTPUT="Agent error: Invalid parameter 'pid'"
      QEMU_EXEC_TRANSPORT_RC=1
      return 0
      ;;
    3)
      QEMU_EXEC_STDOUT=$'guest update complete\n__UU_GUEST_EXIT__0'
      return 0
      ;;
    *) return 0 ;; # cleanup
  esac
}
QEMU_GUEST_EXEC_DURABLE 978 --timeout 5 -- bash -c 'apt-get upgrade -y'
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]
grep -Fq 'guest update complete' <<< "$QEMU_EXEC_STDOUT"
[[ "$durable_call_count" == 4 ]]
[[ $(grep -Fc 'systemd-run' "$durable_calls") == 1 ]]
grep -Fq 'RUN_QEMU_DURABLE "$VM" --timeout 120' "$ROOT_DIR/update.sh"
grep -Fq 'RUN_QEMU_COMMAND "$VM" --timeout 120 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -y"' "$ROOT_DIR/update.sh"
grep -Fq 'DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING upgrade -y' "$ROOT_DIR/update.sh"

echo 'QGA durable guest-job recovery test: PASS'

echo 'QGA guest-exec PID/status contract tests: PASS'
