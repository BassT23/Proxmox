#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^CHECK_GLOBAL_INTERNET_REQUIRED\(\)/,/^}/' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/functions.sh"
awk '/^CHECK_GLOBAL_INTERNET\(\)/,/^}/' "$ROOT_DIR/check-updates.sh" >> "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${WGET_CALLS:-0}" | awk '{print $1 + 1}' > "$WGET_COUNT"
if [[ "${WGET_MODE:-success}" == timeout ]]; then
  sleep 30
fi
EOF
chmod 750 "$WORK_DIR/wget"

cat > "$WORK_DIR/harness.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1/functions.sh"

! CHECK_GLOBAL_INTERNET_REQUIRED cvm
! CHECK_GLOBAL_INTERNET_REQUIRED ccontainer
! CHECK_GLOBAL_INTERNET_REQUIRED cluster
CHECK_GLOBAL_INTERNET_REQUIRED chost
CHECK_GLOBAL_INTERNET_REQUIRED node-host

WGET_COUNT="$1/count" WGET_MODE=success PATH="$1:$PATH" CHECK_URL=192.168.10.1 \
  CHECK_GLOBAL_INTERNET
[[ "$(cat "$1/count")" == 1 ]]

set +e
WGET_COUNT="$1/count" WGET_MODE=timeout UU_GLOBAL_INTERNET_TIMEOUT=1 PATH="$1:$PATH" CHECK_URL=192.168.10.1 \
  CHECK_GLOBAL_INTERNET
timeout_rc=$?
set -e
[[ "$timeout_rc" -ne 0 ]]

echo 'check internet scope: PASS'
EOF
chmod 750 "$WORK_DIR/harness.sh"
(cd "$WORK_DIR" && bash harness.sh "$WORK_DIR")

grep -Fq 'CHECK_GLOBAL_INTERNET_REQUIRED' "$ROOT_DIR/check-updates.sh"
grep -Fq 'timeout --kill-after=2s' "$ROOT_DIR/check-updates.sh"
grep -Fq 'ARGUMENTS "$@"' "$ROOT_DIR/check-updates.sh"

echo 'check internet scope regression: PASS'
