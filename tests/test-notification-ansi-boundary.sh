#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export LOCAL_FILES="$ROOT_DIR"
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the exact notification boundary with both real control bytes and
# literal SGR tokens as they can appear in legacy mail bodies.
source "$ROOT_DIR/status-model.sh"
sample=$(printf 'before\033[1;92mESC-MARKER\033[0m literal [1;33mLITERAL-MARKER[0m before-osc\033]0;ignored-title\007after')
clean=$(printf '%s' "$sample" | STATUS_MODEL_STRIP_ANSI)
[[ "$clean" == 'beforeESC-MARKER literal LITERAL-MARKER before-oscafter' ]]

mail() {
  cat > "$WORK_DIR/mail-body"
}
export -f mail
printf '%s' "$sample" |
  STATUS_MODEL_SEND_HTML_MAIL 'ANSI boundary' sender@example.test recipient@example.test
python3 - "$WORK_DIR/mail-body" <<'PY'
import sys

body = open(sys.argv[1], encoding="utf-8").read()
assert "\x1b" not in body
assert "[1;92m" not in body
assert "[1;33m" not in body
assert "[0m" not in body
assert "ignored-title" not in body
assert "ESC-MARKER" in body
assert "LITERAL-MARKER" in body
PY

# Keep the CLI/log path untouched; only the notification boundary is sanitized.
printf '%s' "$sample" > "$WORK_DIR/cli-output"
python3 - "$WORK_DIR/cli-output" <<'PY'
import sys

body = open(sys.argv[1], "rb").read()
assert b"\x1b[1;92m" in body
assert b"[1;33m" in body
PY

grep -Fq 's/\[[0-9]{1,3}(;[0-9]{1,3})*m//g' "$ROOT_DIR/update.sh"
grep -Fq 's/\[[0-9]{1,3}(;[0-9]{1,3})*m//g' "$ROOT_DIR/check-updates.sh"

echo 'notification ANSI boundary tests: PASS'
