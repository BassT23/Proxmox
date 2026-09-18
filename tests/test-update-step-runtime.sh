#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

COUNTER="$WORK_DIR/count"
printf '0\n' > "$COUNTER"

cat > "$WORK_DIR/fail-once" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$UU_TEST_COUNTER")
printf '%s\n' "$((count + 1))" > "$UU_TEST_COUNTER"
printf 'fixture stdout\n'
printf 'fixture stderr\n' >&2
exit 23
EOF
chmod 750 "$WORK_DIR/fail-once"

# shellcheck source=/dev/null
source "$ROOT_DIR/target-runtime.sh"

ERROR_CALLS=0
ERROR() {
  ERROR_CALLS=$((ERROR_CALLS + 1))
  return "${ERROR_CODE:-1}"
}

export UU_TEST_COUNTER="$COUNTER"
HOSTNAME=fixture-host

set +e
RUN_HOST_STEP "$WORK_DIR/fail-once" > "$WORK_DIR/output" 2>&1
rc=$?
set -e

[[ "$rc" -eq 23 ]]
[[ "$(cat "$COUNTER")" -eq 1 ]]
[[ "$ERROR_CALLS" -eq 1 ]]
[[ "$ERROR_CODE" -eq 23 ]]
[[ "$ID" == fixture-host ]]
[[ "$NAME" == fixture-host ]]
grep -Fq 'fixture stdout' "$WORK_DIR/output"
grep -Fq 'fixture stderr' "$WORK_DIR/output"
grep -Fq 'fixture stdout' <<< "$ERROR_MSG"
grep -Fq 'fixture stderr' <<< "$ERROR_MSG"

printf 'Single-execution update runtime: PASS\n'
