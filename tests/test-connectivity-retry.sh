#!/usr/bin/env bash
# shellcheck disable=SC2016  # source assertions intentionally use literals
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Load only the production preflight functions.  The retry tests use a mock
# probe, so no pct, SSH, QGA, DNS, or network operation can run.
awk '/^GUEST_INTERNET_PREFLIGHT_COMMAND\(\)/,/^# Wait for bootup/' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/preflight-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

source "$1/preflight-functions.sh"

CHECK_URL=example.invalid
EXE_FOR_INTERNET_CHECK=ping
probe_calls=0
sleep_calls=0

sleep() {
  [[ "${1:-}" == 1 ]] || {
    echo "unexpected retry delay: ${1:-}" >&2
    return 1
  }
  sleep_calls=$((sleep_calls + 1))
}

GUEST_INTERNET_PREFLIGHT_PCT() {
  probe_calls=$((probe_calls + 1))
  [[ "$probe_calls" -eq 2 ]]
}

GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_PCT 910
[[ "$probe_calls" -eq 2 && "$sleep_calls" -eq 1 ]]

probe_calls=0
sleep_calls=0
GUEST_INTERNET_PREFLIGHT_PCT() {
  probe_calls=$((probe_calls + 1))
  return 1
}
if GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_PCT 910; then
  echo 'persistent connectivity failure unexpectedly succeeded' >&2
  exit 1
fi
[[ "$probe_calls" -eq 2 && "$sleep_calls" -eq 1 ]]

# Invalid local probe configuration is rejected before any guest contact and
# therefore does not trigger a retry.
CHECK_URL=''
probe_calls=0
sleep_calls=0
if GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_PCT 910; then
  echo 'invalid connectivity configuration unexpectedly succeeded' >&2
  exit 1
fi
[[ "$probe_calls" -eq 0 && "$sleep_calls" -eq 0 ]]

# A missing helper is fail-closed and cannot cause a retry storm.
CHECK_URL=example.invalid
probe_calls=0
sleep_calls=0
if GUEST_INTERNET_PREFLIGHT_RETRY missing_preflight_helper 910; then
  echo 'missing preflight helper unexpectedly succeeded' >&2
  exit 1
fi
[[ "$probe_calls" -eq 0 && "$sleep_calls" -eq 0 ]]
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

bash "$WORK_DIR/harness.sh" "$WORK_DIR"

# Exercise the production LXC check path.  The first guest connectivity probe
# fails, the bounded retry succeeds, and only then may the read-only package
# count run.  No lifecycle command is available in this fixture.
awk '/^# Container Check$/,/^## VM ##/' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/container-functions.sh"
cat > "$WORK_DIR/lxc-check.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

LOCAL_FILES="$PWD/local-files"
mkdir -p "$LOCAL_FILES"
CHECK_URL=example.invalid
EXE_FOR_INTERNET_CHECK=ping
INITIAL_INVENTORY=false
RDU=false
STATUS_MODEL_NODE=test-node
STATUS_MODEL_RECORD_FILE="$PWD/lxc-records"
YL=''
CL=''
probe_calls=0

STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$STATUS_MODEL_RECORD_FILE"; }
CHECK_CONTAINER_FAILURE() { return 1; }
SANITIZE_NUMBER() { printf '%s' "$1"; }
cluster_target_guest_name() { printf 'fixture-lxc\n'; }
APT_COUNT_REMOTE_COMMAND() { printf ':'; }
RPM_COUNT_REMOTE_COMMAND() { printf ':'; }
PACKAGE_COUNT_REMOTE_COMMAND() { printf ':'; }
PARSE_APT_UPDATE_COUNTS() {
  NORMAL_APT_UPDATES=0
  SECURITY_APT_UPDATES=0
  return 0
}
PARSE_RPM_UPDATE_COUNTS() { RPM_COUNTS_TOTAL=0; return 0; }
PARSE_PACKAGE_UPDATE_COUNTS() { PACKAGE_COUNTS_TOTAL=0; return 0; }

pct() {
  [[ "${1:-}" == config && "${2:-}" == 910 ]] || return 1
  printf 'ostype: debian\nhostname: fixture-lxc\n'
}

RUN_PCT_COMMAND() {
  local target="$1" shell="$2" flag="${3:-}" command="${4:-}"
  if [[ "$shell" == hostname ]]; then
    printf 'fixture-lxc\n'
    return 0
  fi
  [[ "$target" == 910 && "$flag" == -c ]] || return 1
  if [[ "$command" == *ping* ]]; then
    probe_calls=$((probe_calls + 1))
    [[ "$probe_calls" -eq 2 ]]
    return
  fi
  if [[ "$command" == 'cat /etc/os-release' ]]; then
    printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12"\n'
    return 0
  fi
  [[ "$shell" == bash ]] && return 0
  return 0
}

source "$1/preflight-functions.sh"
source "$1/container-functions.sh"
set +e
CHECK_CONTAINER 910
check_rc=$?
set -e
[[ "$check_rc" -eq 0 ]] || {
  echo "CHECK_CONTAINER failed with rc=$check_rc" >&2
  cat "$STATUS_MODEL_RECORD_FILE" 2>/dev/null || true
  exit 1
}
[[ "$probe_calls" -eq 2 ]]
grep -Fq '910 lxc pct true Debian GNU/Linux 12 debian 0 false ok' "$STATUS_MODEL_RECORD_FILE" || {
  cat "$STATUS_MODEL_RECORD_FILE" >&2
  exit 1
}
HARNESS
chmod 750 "$WORK_DIR/lxc-check.sh"
(cd "$WORK_DIR" && bash lxc-check.sh "$WORK_DIR")

# The production call sites retain the existing selection/lifecycle gates and
# apply the retry only to the three read-only guest probes.  External-APT has
# a separate SSH/result protocol and is intentionally not wrapped here.
[[ "$(grep -Fc 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_PCT' "$ROOT_DIR/check-updates.sh")" -eq 1 ]]
[[ "$(grep -Fc 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_SSH' "$ROOT_DIR/check-updates.sh")" -eq 1 ]]
[[ "$(grep -Fc 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_QGA' "$ROOT_DIR/check-updates.sh")" -eq 1 ]]
grep -Fq 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_PCT "$CONTAINER"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_SSH "$IP" "$SSH_VM_PORT" "$USER"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'GUEST_INTERNET_PREFLIGHT_RETRY GUEST_INTERNET_PREFLIGHT_QGA "$VM"' "$ROOT_DIR/check-updates.sh"

printf '%s\n' 'bounded guest connectivity retry tests: PASS'
