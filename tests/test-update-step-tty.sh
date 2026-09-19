#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

COUNTER="$WORK_DIR/count"
printf '0\n' > "$COUNTER"

cat > "$WORK_DIR/tty-probe" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$UU_TEST_COUNTER")
printf '%s\n' "$((count + 1))" > "$UU_TEST_COUNTER"
[[ -t 0 ]] && printf 'EXTERNAL_STDIN_TTY=YES\n' || printf 'EXTERNAL_STDIN_TTY=NO\n'
[[ -t 1 ]] && printf 'EXTERNAL_STDOUT_TTY=YES\n' || printf 'EXTERNAL_STDOUT_TTY=NO\n'
[[ -t 2 ]] && printf 'EXTERNAL_STDERR_TTY=YES\n' >&2 || printf 'EXTERNAL_STDERR_TTY=NO\n' >&2
printf 'external stdout marker\n'
printf 'external stderr marker\n' >&2
exit 23
EOF
chmod 750 "$WORK_DIR/tty-probe"

HARNESS="$WORK_DIR/harness.sh"
cat > "$HARNESS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$UU_TEST_ROOT/target-runtime.sh"

ERROR_CALLS=0
ERROR() {
  ERROR_CALLS=$((ERROR_CALLS + 1))
  return "${ERROR_CODE:-1}"
}

HOSTNAME=fixture-host

set +e
RUN_HOST_STEP "$UU_TEST_PROBE"
external_rc=$?
set -e
printf 'EXTERNAL_RC=%s\n' "$external_rc"
printf 'EXTERNAL_ERROR_CALLS=%s\n' "$ERROR_CALLS"
printf 'EXTERNAL_ERROR_CODE=%s\n' "$ERROR_CODE"
printf 'EXTERNAL_ERROR_MSG=%s\n' "$ERROR_MSG"

tty_function_probe() {
  [[ -t 0 ]] && printf 'FUNCTION_STDIN_TTY=YES\n' || printf 'FUNCTION_STDIN_TTY=NO\n'
  [[ -t 1 ]] && printf 'FUNCTION_STDOUT_TTY=YES\n' || printf 'FUNCTION_STDOUT_TTY=NO\n'
  [[ -t 2 ]] && printf 'FUNCTION_STDERR_TTY=YES\n' >&2 || printf 'FUNCTION_STDERR_TTY=NO\n' >&2
  return 24
}

ERROR_CALLS=0
set +e
RUN_HOST_STEP tty_function_probe
function_rc=$?
set -e
printf 'FUNCTION_RC=%s\n' "$function_rc"
printf 'FUNCTION_ERROR_CALLS=%s\n' "$ERROR_CALLS"
printf 'FUNCTION_ERROR_CODE=%s\n' "$ERROR_CODE"
printf 'FUNCTION_ERROR_MSG=%s\n' "$ERROR_MSG"
EOF
chmod 750 "$HARNESS"

export UU_TEST_ROOT="$ROOT_DIR"
export UU_TEST_PROBE="$WORK_DIR/tty-probe"
export UU_TEST_COUNTER="$COUNTER"

pty_output=$(script -qef /dev/null -- bash "$HARNESS" | tr -d '\r')

[[ $(cat "$COUNTER") -eq 1 ]]
grep -Fq 'EXTERNAL_STDIN_TTY=YES' <<<"$pty_output"
grep -Fq 'EXTERNAL_STDOUT_TTY=YES' <<<"$pty_output"
grep -Fq 'EXTERNAL_STDERR_TTY=YES' <<<"$pty_output"
grep -Fq 'EXTERNAL_RC=23' <<<"$pty_output"
grep -Fq 'EXTERNAL_ERROR_CALLS=1' <<<"$pty_output"
grep -Fq 'EXTERNAL_ERROR_CODE=23' <<<"$pty_output"
grep -Fq 'EXTERNAL_ERROR_MSG=external stdout marker' <<<"$pty_output"
grep -Fq 'external stderr marker' <<<"$pty_output"

grep -Fq 'FUNCTION_STDIN_TTY=YES' <<<"$pty_output"
grep -Fq 'FUNCTION_STDOUT_TTY=YES' <<<"$pty_output"
grep -Fq 'FUNCTION_STDERR_TTY=YES' <<<"$pty_output"
grep -Fq 'FUNCTION_RC=24' <<<"$pty_output"
grep -Fq 'FUNCTION_ERROR_CALLS=1' <<<"$pty_output"
grep -Fq 'FUNCTION_ERROR_CODE=24' <<<"$pty_output"
grep -Fq 'FUNCTION_ERROR_MSG=Interactive command failed with exit code 24: tty_function_probe' <<<"$pty_output"

printf 'Interactive update-step TTY semantics: PASS\n'
