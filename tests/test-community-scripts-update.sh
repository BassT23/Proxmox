#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true' EXIT

mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/update.conf" <<'EOF'
INCLUDE_HELPER_SCRIPTS="true"
EOF

cat > "$WORK_DIR/bin/update" <<'EOF'
#!/usr/bin/env bash
# community-scripts marker keeps this fixture on the intended code path.
case "${COMMUNITY_TEST_MODE:-success}" in
  success)
    if [[ -n "${COMMUNITY_TEST_COUNT_FILE:-}" ]]; then
      printf '%s\n' "$PPID" >> "$COMMUNITY_TEST_COUNT_FILE"
    fi
    printf 'helper output\n'
    exit 0
    ;;
  failure)
    printf 'helper error\n' >&2
    exit 7
    ;;
  empty)
    exit 0
    ;;
  long)
    printf 'long job started\n'
    sleep 1
    printf 'long job finished\n'
    exit 0
    ;;
esac
EOF
chmod 750 "$WORK_DIR/bin/update"

run_helper() {
  local mode="$1"
  PATH="$WORK_DIR/bin:$PATH" \
    UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
    UU_COMMUNITY_UPDATE_COMMAND=update \
    COMMUNITY_TEST_MODE="$mode" \
    COMMUNITY_TEST_COUNT_FILE="${COMMUNITY_TEST_COUNT_FILE:-}" \
    bash "$ROOT_DIR/update-extras.sh"
}

count_file="$WORK_DIR/invocations"
success_output=$(COMMUNITY_TEST_COUNT_FILE="$count_file" run_helper success)
grep -Fq 'helper output' <<<"$success_output"
grep -Fq '✅ Update process completed' <<<"$success_output"
[[ $(wc -l < "$count_file") == 1 ]]

set +e
failure_output=$(run_helper failure 2>&1)
failure_rc=$?
set -e
[[ $failure_rc == 0 ]]
grep -Fq 'helper error' <<<"$failure_output"
grep -Fq 'exit code 7' <<<"$failure_output"
if grep -Fq '✅ Update process completed' <<<"$failure_output"; then
  echo 'failure must not report success' >&2
  exit 1
fi

empty_output=$(run_helper empty)
grep -Fq '✅ Update process completed' <<<"$empty_output"

long_output=$(run_helper long)
grep -Fq 'long job started' <<<"$long_output"
grep -Fq 'long job finished' <<<"$long_output"

if grep -Fq 'timeout 1800s' "$ROOT_DIR/update-extras.sh"; then
  echo 'community update must not use a hard timeout' >&2
  exit 1
fi
grep -Fq "COMMUNITY_UPDATE_EXIT=\${PIPESTATUS[0]}" "$ROOT_DIR/update-extras.sh"
grep -Fq "COMMUNITY_UPDATE_COMMAND=\"\${UU_COMMUNITY_UPDATE_COMMAND:-update}\"" "$ROOT_DIR/update-extras.sh"

echo 'Community-Scripts update handling tests: PASS'
