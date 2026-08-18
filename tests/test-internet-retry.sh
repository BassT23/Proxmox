#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

sed -n '/^CHECK_INTERNET () {/,/^}/p' "$ROOT_DIR/update.sh" > "$WORK_DIR/check.sh"
cat > "$WORK_DIR/probe.sh" <<'EOF'
#!/usr/bin/env bash
count_file=${RETRY_COUNT_FILE:?}
count=$(cat "$count_file" 2>/dev/null || printf '0')
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
exit "${PROBE_RESULT:-0}"
EOF
chmod +x "$WORK_DIR/probe.sh"

run_case() {
  local expected_count="$1" result="$2" expected_rc="$3"
  printf '0\n' > "$WORK_DIR/count"
  set +e
  PROBE_RESULT="$result" RETRY_COUNT_FILE="$WORK_DIR/count" \
    CHECK_URL_EXE="$WORK_DIR/probe.sh" CHECK_URL=example.test \
    bash -c 'source "$1"; sleep(){ :; }; CHECK_INTERNET' _ "$WORK_DIR/check.sh" \
    >"$WORK_DIR/output" 2>"$WORK_DIR/error"
  local rc=$?
  set -e
  [[ "$rc" -eq "$expected_rc" ]]
  [[ "$(cat "$WORK_DIR/count")" -eq "$expected_count" ]]
}

# Immediate success: no retry.
run_case 1 0 0

# A transient failure is retried and then succeeds.
printf '0\n' > "$WORK_DIR/count"
cat > "$WORK_DIR/probe-sequence.sh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$RETRY_COUNT_FILE" 2>/dev/null || printf '0'); count=$((count + 1)); printf '%s\n' "$count" > "$RETRY_COUNT_FILE"
[[ "$count" -eq 1 ]] && exit 1
exit 0
EOF
chmod +x "$WORK_DIR/probe-sequence.sh"
RETRY_COUNT_FILE="$WORK_DIR/count" CHECK_URL_EXE="$WORK_DIR/probe-sequence.sh" CHECK_URL=example.test \
  bash -c 'source "$1"; sleep(){ :; }; CHECK_INTERNET' _ "$WORK_DIR/check.sh" >/dev/null
[[ "$(cat "$WORK_DIR/count")" -eq 2 ]]

# All attempts fail with the historical exit code.
run_case 3 1 2

echo 'internet retry tests: PASS'
