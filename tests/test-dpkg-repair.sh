#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Extract only the side-effect-free repair implementation. The fixture runner
# below replaces every transport, so no local or guest package command runs.
awk '
  /^# Optional dpkg repair is deliberately/ { capture=1 }
  /^# Tag filter/ { capture=0 }
  capture
' "$ROOT_DIR/update.sh" > "$WORK_DIR/dpkg-repair.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
source "$1"

MOCK_STATE=clean
MOCK_AUDIT_FAILURE=false
MOCK_REPAIR_FAILURE=false
MOCK_LOG="$2/mock.log"
declare -A DPKG_REPAIR_CHECKED=()

timeout() { printf 'timeout %s\n' "$*" >> "$MOCK_LOG"; }
dpkg() { printf 'dpkg %s\n' "$*" >> "$MOCK_LOG"; }
RUN_PCT_COMMAND() { printf 'pct %s\n' "$*" >> "$MOCK_LOG"; }
RUN_SSH_COMMAND() { printf 'ssh %s\n' "$*" >> "$MOCK_LOG"; }
RUN_QEMU_COMMAND() { printf 'qga %s\n' "$*" >> "$MOCK_LOG"; }

mock_runner() {
  local action="$1"
  printf '%s\n' "$action" >> "$MOCK_LOG"
  case "$action" in
    audit)
      if [[ "$MOCK_AUDIT_FAILURE" == true ]]; then
        return 124
      fi
      if [[ "$MOCK_STATE" == broken ]]; then
        printf 'The following packages have been unpacked but not configured.\n'
      fi
      return 0
      ;;
    repair)
      [[ "$MOCK_REPAIR_FAILURE" == true ]] && return 1
      MOCK_STATE=clean
      ;;
    *) return 2 ;;
  esac
}

APT_AUTO_REPAIR_DPKG=false
DPKG_REPAIR_PREPARE lxc:disabled 'LXC disabled' mock_runner
[[ ! -s "$MOCK_LOG" ]]

# Transport wrappers are exercised with command shims only; no dpkg, pct, SSH,
# or QGA process is started by this fixture.
DPKG_REPAIR_RUN_LOCAL audit
DPKG_REPAIR_RUN_LOCAL repair
DPKG_REPAIR_RUN_LXC audit 115
DPKG_REPAIR_RUN_LXC repair 115
DPKG_REPAIR_RUN_SSH audit 127.0.0.1 22 root
DPKG_REPAIR_RUN_SSH repair 127.0.0.1 22 root
DPKG_REPAIR_RUN_QGA audit 986
DPKG_REPAIR_RUN_QGA repair 986
grep -Fq 'dpkg --audit' "$MOCK_LOG"
grep -Fq 'pct 115 bash -c dpkg --audit' "$MOCK_LOG"
grep -Fq 'ssh 127.0.0.1 22 root bash -c dpkg --audit' "$MOCK_LOG"
grep -Fq 'qga 986 --timeout 120 -- bash -c dpkg --audit' "$MOCK_LOG"
: > "$MOCK_LOG"

APT_AUTO_REPAIR_DPKG=true
DPKG_REPAIR_CHECKED=()
: > "$MOCK_LOG"
MOCK_STATE=clean
DPKG_REPAIR_PREPARE lxc:clean 'LXC clean' mock_runner
[[ "$(wc -l < "$MOCK_LOG")" -eq 1 ]]
grep -Fxq audit "$MOCK_LOG"

DPKG_REPAIR_CHECKED=()
: > "$MOCK_LOG"
MOCK_STATE=broken
DPKG_REPAIR_PREPARE lxc:broken 'LXC broken' mock_runner > "$2/broken.out"
[[ "$(grep -c '^repair$' "$MOCK_LOG")" -eq 1 ]]
[[ "$(grep -c '^audit$' "$MOCK_LOG")" -eq 2 ]]
grep -Fq 'DPKG_REPAIR_BEGIN: LXC broken' "$2/broken.out"
grep -Fq 'DPKG_REPAIR_COMPLETE: LXC broken' "$2/broken.out"

# A second call for the same target cannot repair twice.
before=$(wc -l < "$MOCK_LOG")
DPKG_REPAIR_PREPARE lxc:broken 'LXC broken' mock_runner
[[ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]]

DPKG_REPAIR_CHECKED=()
: > "$MOCK_LOG"
MOCK_STATE=broken
MOCK_REPAIR_FAILURE=true
if DPKG_REPAIR_PREPARE lxc:failed 'LXC failed' mock_runner > "$2/failed.out" 2>&1; then
  echo 'failed repair unexpectedly succeeded' >&2
  exit 1
fi
[[ "$DPKG_REPAIR_ERROR" == DPKG_REPAIR_FAILED ]]
[[ "$(grep -c '^repair$' "$MOCK_LOG")" -eq 1 ]]

DPKG_REPAIR_CHECKED=()
DPKG_REPAIR_PERFORMED=()
: > "$MOCK_LOG"
MOCK_STATE=broken
MOCK_REPAIR_FAILURE=false
MOCK_AUDIT_FAILURE=true
DPKG_REPAIR_PREPARE lxc:unavailable 'LXC unavailable' mock_runner > "$2/unavailable.out"
[[ "$(grep -c '^repair$' "$MOCK_LOG")" -eq 0 ]]
grep -Fq DPKG_REPAIR_CHECK_UNAVAILABLE "$2/unavailable.out"

echo 'dpkg repair core fixtures: PASS'
HARNESS
chmod 750 "$WORK_DIR/harness.sh"
mkdir -p "$WORK_DIR/output"
bash "$WORK_DIR/harness.sh" "$WORK_DIR/dpkg-repair.sh" "$WORK_DIR/output"

# Static coverage ensures all supported APT transports are gated after their
# existing protection path, while the external updater remains untouched.
[[ $(grep -c 'DPKG_REPAIR_PREPARE' "$ROOT_DIR/update.sh") -ge 5 ]]
grep -Fq "APT_AUTO_REPAIR_DPKG=\$(awk" "$ROOT_DIR/update.sh"
grep -Fq 'APT_AUTO_REPAIR_DPKG="false"' "$ROOT_DIR/update.conf.dist"
grep -Fq 'DPKG_REPAIR_PREPARE "host:' "$ROOT_DIR/update.sh"
grep -Fq "DPKG_REPAIR_PREPARE \"lxc:\$CONTAINER\"" "$ROOT_DIR/update.sh"
grep -Fq "DPKG_REPAIR_PREPARE \"vm:\$VM\" \"VM \$VM via SSH\"" "$ROOT_DIR/update.sh"
grep -Fq "DPKG_REPAIR_PREPARE \"vm:\$VM\" \"VM \$VM via QEMU Guest Agent\"" "$ROOT_DIR/update.sh"
if grep -q 'DPKG_REPAIR' "$ROOT_DIR/external-apt.sh"; then
  echo 'external-apt.sh unexpectedly contains dpkg repair logic' >&2
  exit 1
fi

echo 'dpkg repair integration boundaries: PASS'
