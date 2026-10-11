#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/qm" <<'MOCK'
#!/usr/bin/env bash
set -u
case "$1 ${2:-}" in
  "guest exec-status")
    n=$(($(grep -c '^status$' "$QGA_CALLS" 2>/dev/null || true) + 1))
    printf '%s\n' status >> "$QGA_CALLS"
    if [[ "$QGA_STATUS_FAIL_ONCE" == true && "$n" == 1 ]]; then
      printf '%s\n' "got wrong command id 'stale' (expected current)" >&2
      exit 255
    fi
    printf '%s\n' '{"exited":true,"exitcode":0,"out-data":"ok\n"}'
    ;;
  *)
    n=$(($(grep -c '^exec$' "$QGA_CALLS" 2>/dev/null || true) + 1))
    printf '%s\n' exec >> "$QGA_CALLS"
    if [[ "${QGA_START_HANG:-false}" == true ]]; then
      sleep 10
    fi
    if [[ "$QGA_START_FAIL_ONCE" == true && "$n" == 1 ]]; then
      printf '%s\n' 'guest-exec timeout' >&2
      exit 255
    fi
    printf '%s\n' '{"pid":1234}'
    ;;
esac
MOCK
chmod 750 "$WORK_DIR/qm"

source "$ROOT_DIR/qga-guest-exec.sh"
export PATH="$WORK_DIR:$PATH"
export QGA_CALLS="$WORK_DIR/calls"

: > "$QGA_CALLS"
export QGA_STATUS_FAIL_ONCE=true QGA_START_FAIL_ONCE=false
QEMU_GUEST_EXEC_READONLY 310 --timeout 5 -- /bin/true
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]
[[ $(grep -c '^exec$' "$QGA_CALLS") == 1 ]]
[[ $(grep -c '^status$' "$QGA_CALLS") == 2 ]]

: > "$QGA_CALLS"
export QGA_STATUS_FAIL_ONCE=false QGA_START_FAIL_ONCE=true
QEMU_GUEST_EXEC_READONLY 310 --timeout 5 -- /bin/true
[[ "$QEMU_EXEC_TRANSPORT_RC" == 0 && "$QEMU_EXEC_EXITCODE" == 0 ]]
[[ $(grep -c '^exec$' "$QGA_CALLS") == 2 ]]

: > "$QGA_CALLS"
QEMU_GUEST_EXEC 310 --timeout 5 -- /bin/true || true
[[ "$QEMU_EXEC_TRANSPORT_RC" == 255 ]]
[[ $(grep -c '^exec$' "$QGA_CALLS") == 1 ]]

: > "$QGA_CALLS"
export QGA_START_HANG=true UU_QGA_GUEST_EXEC_START_TIMEOUT=1
QEMU_GUEST_EXEC_READONLY 310 --timeout 5 -- /bin/true || true
[[ "$QEMU_EXEC_ERROR_CLASS" == QGA_START_TIMEOUT ]]
[[ "$QEMU_EXEC_TRANSPORT_RC" == 124 ]]
[[ $(grep -c '^exec$' "$QGA_CALLS") == 1 ]]
unset QGA_START_HANG UU_QGA_GUEST_EXEC_START_TIMEOUT

echo 'QGA read-only retry and mutation safety: PASS'
