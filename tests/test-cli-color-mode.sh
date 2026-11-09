#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Extract only the production colour initialisation blocks.  This exercises
# the exact code used by both entrypoints without starting an update/check.
awk '/^# Colors$/{copy=1; next} /^DOWNLOAD_SHELL_FILE\(\)/{exit} copy{print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-colors.sh"
awk '/^# Colors$/{copy=1; next} /^SANITIZE_NUMBER\(\)/{exit} copy{print}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-colors.sh"

cat > "$WORK_DIR/probe.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STATUS_MODEL_SOURCE:-}" ]]; then
  source "$STATUS_MODEL_SOURCE"
fi
source "${COLOR_BLOCK:?}"
printf '%bMARKER%b\n' "$OR" "$CL"
EOF
chmod 750 "$WORK_DIR/probe.sh"
export LOCAL_FILES="$ROOT_DIR"

assert_no_ansi() {
  local output_file="$1"
  python3 - "$output_file" <<'PY'
import sys

body = open(sys.argv[1], "rb").read()
assert b"\x1b" not in body, f"ANSI ESC leaked into {sys.argv[1]}"
assert b"[1;33m" not in body, f"literal SGR leaked into {sys.argv[1]}"
assert b"[0m" not in body, f"literal reset leaked into {sys.argv[1]}"
assert b"MARKER" in body
PY
}

assert_has_ansi() {
  local output_file="$1"
  python3 - "$output_file" <<'PY'
import sys

body = open(sys.argv[1], "rb").read()
assert b"\x1b[1;33m" in body, f"interactive colour missing from {sys.argv[1]}"
assert b"MARKER" in body
PY
}

for entrypoint in update check; do
  export STATUS_MODEL_SOURCE="$ROOT_DIR/status-model.sh"
  export COLOR_BLOCK="$WORK_DIR/${entrypoint}-colors.sh"

  # A normal pipe/redirect must not receive colour control bytes.
  env -u NO_COLOR UU_COLOR=auto TERM=xterm bash "$WORK_DIR/probe.sh" \
    > "$WORK_DIR/${entrypoint}-pipe.out" 2> "$WORK_DIR/${entrypoint}-pipe.err"
  assert_no_ansi "$WORK_DIR/${entrypoint}-pipe.out"

  # The fallback block is used by older/partial installations without the
  # shared status-model helper and must have the same non-TTY behaviour.
  env -u NO_COLOR -u STATUS_MODEL_SOURCE UU_COLOR=auto TERM=xterm \
    bash "$WORK_DIR/probe.sh" > "$WORK_DIR/${entrypoint}-fallback.out" \
    2> "$WORK_DIR/${entrypoint}-fallback.err"
  assert_no_ansi "$WORK_DIR/${entrypoint}-fallback.out"

  # Explicit opt-in remains available for callers that intentionally need
  # colour in a non-interactive stream.
  env -u NO_COLOR UU_COLOR=always TERM=xterm bash "$WORK_DIR/probe.sh" \
    > "$WORK_DIR/${entrypoint}-forced.out" 2> "$WORK_DIR/${entrypoint}-forced.err"
  assert_has_ansi "$WORK_DIR/${entrypoint}-forced.out"

  # Explicit suppression wins even when a caller requests automatic colours.
  NO_COLOR=1 UU_COLOR=auto TERM=xterm bash "$WORK_DIR/probe.sh" \
    > "$WORK_DIR/${entrypoint}-no-color.out" 2> "$WORK_DIR/${entrypoint}-no-color.err"
  assert_no_ansi "$WORK_DIR/${entrypoint}-no-color.out"
done

if command -v script >/dev/null 2>&1; then
  export STATUS_MODEL_SOURCE="$ROOT_DIR/status-model.sh"
  export COLOR_BLOCK="$WORK_DIR/update-colors.sh"
  env -u NO_COLOR UU_COLOR=auto TERM=xterm \
    script -qec "bash '$WORK_DIR/probe.sh'" /dev/null \
    > "$WORK_DIR/tty.out" 2> "$WORK_DIR/tty.err"
  assert_has_ansi "$WORK_DIR/tty.out"
else
  printf '%s\n' 'TTY colour probe: NOT RUN (script command unavailable)' >&2
fi

printf '%s\n' 'CLI colour mode tests: PASS'
