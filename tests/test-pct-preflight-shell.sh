#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Extract only the production preflight functions.  The test deliberately
# rejects bash as a guest interpreter, modelling a minimal Alpine LXC.
awk '/^GUEST_INTERNET_PREFLIGHT_COMMAND\(\)/,/^# Wait for bootup/' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/preflight-functions.sh"
sed -n '/^WAIT_FOR_BOOTUP_LXC () {/,/^}$/p' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/lifecycle-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

source "$1/preflight-functions.sh"
source "$1/lifecycle-functions.sh"

RUN_PCT_COMMAND() {
  local target="$1" shell="$2" flag="$3" command="$4"
  [[ "$target" == 914 ]] || return 97
  [[ "$shell" == sh ]] || {
    echo "unexpected guest shell: $shell" >&2
    return 98
  }
  [[ "$flag" == -c ]] || return 99
  [[ "${UU_CHECK_PCT_COMMAND_TIMEOUT:-}" == 5 ]] || return 100
  "$shell" "$flag" "$command"
}

pct() {
  [[ "${1:-}" == exec && "${3:-}" == -- && "${4:-}" == sh && "${5:-}" == -c && "${6:-}" == exit ]]
}

sleep() { :; }
timeout() { shift; "$@"; }

EXE_FOR_INTERNET_CHECK=:
CHECK_URL=example.invalid
GUEST_INTERNET_PREFLIGHT_PCT 914

CONTAINER=914
LXC_START_DELAY=0
WAIT_FOR_BOOTUP_LXC

EXE_FOR_INTERNET_CHECK=false
if GUEST_INTERNET_PREFLIGHT_PCT 914; then
  echo 'failed connectivity probe unexpectedly succeeded' >&2
  exit 1
fi

# A Debian-like guest with /bin/sh follows the same portable path; no bash
# dependency is introduced for guests that also happen to have bash.
EXE_FOR_INTERNET_CHECK=:
CHECK_URL=example.invalid
GUEST_INTERNET_PREFLIGHT_PCT 914
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

bash "$WORK_DIR/harness.sh" "$WORK_DIR"
echo "PCT guest preflight shell portability tests: PASS"
