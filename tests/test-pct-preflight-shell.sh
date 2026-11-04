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
  PCT_CALLS=$((PCT_CALLS + 1))
  [[ "$target" == 914 ]] || return 97
  [[ "$shell" == sh ]] || {
    echo "unexpected guest shell: $shell" >&2
    return 98
  }
  [[ "$flag" == -c ]] || return 99
  [[ "${UU_CHECK_PCT_COMMAND_TIMEOUT:-}" == 5 ]] || return 100
  if [[ -n "${PCT_RC_OVERRIDE:-}" ]]; then
    return "$PCT_RC_OVERRIDE"
  fi
  "$shell" "$flag" "$command"
}

pct() {
  [[ "${1:-}" == exec && "${3:-}" == -- && "${4:-}" == sh && "${5:-}" == -c && "${6:-}" == exit ]]
}

sleep() { :; }
timeout() { shift; "$@"; }

mkdir -p "$1/bin"
cat > "$1/bin/ping-hup" <<'PING'
#!/bin/sh
kill -HUP "$$"
PING
cat > "$1/bin/ping-fail" <<'PING'
#!/bin/sh
exit 1
PING
chmod 750 "$1/bin"/ping-*
PCT_CALLS=0

# Before the fix, a last-command shell optimization could replace the guest
# shell with ping.  A PTY cleanup SIGHUP then produced 129 despite ping's
# intended success result.
set +e
sh -c "$1/bin/ping-hup -q -c1 example.invalid >/dev/null 2>&1"
old_rc=$?
set -e
[[ "$old_rc" -eq 129 ]] || {
  echo "fixture did not reproduce the old SIGHUP/129 behavior: $old_rc" >&2
  exit 1
}

# The proposed PR wrapper preserves the last command's status, but does not
# change the inherited SIGHUP disposition and therefore does not fix this
# transport/PTY failure mode by itself.
set +e
sh -c "$1/bin/ping-hup -q -c1 example.invalid >/dev/null 2>&1; rc=\$?; exit \"\$rc\""
candidate_rc=$?
set -e
[[ "$candidate_rc" -eq 129 ]] || {
  echo "three-line candidate did not reproduce the SIGHUP/129 behavior: $candidate_rc" >&2
  exit 1
}

EXE_FOR_INTERNET_CHECK="$1/bin/ping-hup" CHECK_URL=example.invalid GUEST_INTERNET_PREFLIGHT_PCT 914
set +e
EXE_FOR_INTERNET_CHECK="$1/bin/ping-fail" CHECK_URL=example.invalid GUEST_INTERNET_PREFLIGHT_PCT 914
normal_ping_rc=$?
set -e
[[ "$normal_ping_rc" -eq 1 ]] || exit 1

PCT_RC_OVERRIDE=129
set +e
EXE_FOR_INTERNET_CHECK="$1/bin/ping-fail" CHECK_URL=example.invalid GUEST_INTERNET_PREFLIGHT_PCT 914
transport_rc=$?
set -e
[[ "$transport_rc" -eq 129 ]] || exit 1

PCT_RC_OVERRIDE=
set +e
CHECK_URL= GUEST_INTERNET_PREFLIGHT_PCT 914
invalid_url_rc=$?
set -e
[[ "$invalid_url_rc" -eq 1 ]] || exit 1
[[ "$PCT_CALLS" -eq 3 ]] || {
  echo "invalid URL contacted the guest: $PCT_CALLS calls" >&2
  exit 1
}

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
