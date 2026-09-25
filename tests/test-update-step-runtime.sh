#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

awk '/^RUN_UPDATE_COMMAND\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/runtime.sh"
cat > "$WORK_DIR/mutator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$MUTATOR_MODE" >> "$MUTATOR_COUNT"
printf 'stdout from mutator\n'
printf 'stderr from mutator\n' >&2
exit "${MUTATOR_RC:-23}"
EOF
chmod +x "$WORK_DIR/mutator"

run_case() {
  local mode=$1
  : > "$WORK_DIR/count-$mode"
  set +e
  output=$(MUTATOR_MODE="$mode" MUTATOR_COUNT="$WORK_DIR/count-$mode" RUN_MODE="$mode" \
    MUTATOR_RC=23 bash -c \
    'source "$1"; EFFECTIVE_HEADLESS() { [[ "$RUN_MODE" == headless ]]; }; RUN_UPDATE_COMMAND "$2/mutator"' \
    _ "$WORK_DIR/runtime.sh" "$WORK_DIR" 2>&1)
  local rc=$?
  set -e
  [[ $rc -eq 23 ]]
  [[ $(wc -l < "$WORK_DIR/count-$mode") -eq 1 ]]
  grep -Fq 'stdout from mutator' <<<"$output"
  grep -Fq 'stderr from mutator' <<<"$output"
}

run_case headless
run_case interactive

echo 'single-execution runtime tests: PASS'
