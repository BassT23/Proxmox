#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# VM checks must use the same named split as the status model.  The old S/N
# shorthand produced incomplete lines when one side of the split was zero.
if grep -Eq 'S: \$|N: \$' "$ROOT_DIR/check-updates.sh"; then
  echo 'legacy VM S/N output remains' >&2
  exit 1
fi
grep -Fq 'PRINT_UPDATE_SPLIT "$NORMAL_APT_UPDATES" "$SECURITY_APT_UPDATES"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'PRINT_UPDATE_SPLIT "$UPDATES" Unknown' "$ROOT_DIR/check-updates.sh"

# Explicit single-VM lifecycle checks must initialize the delay before the
# optional per-VM SSH profile is read; otherwise a direct cvm invocation can
# call sleep with an empty interval.
grep -Fq 'SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "${VM_START_DELAY:-45}")' "$ROOT_DIR/check-updates.sh"
grep -Fq 'SSH_START_DELAY_TIME=${SSH_START_DELAY_TIME:-45}' "$ROOT_DIR/check-updates.sh"

# Freshly started QGA VMs use a bounded readiness deadline with active
# polling, rather than the old short fixed-attempt window.
grep -Fq 'local max_wait=300 interval=5 probe_timeout=3' "$ROOT_DIR/check-updates.sh"
grep -Fq 'timeout "$probe_timeout" qm agent "$VM" ping' "$ROOT_DIR/check-updates.sh"
grep -Fq 'QEMU Guest Agent did not become ready within ${max_wait} seconds' "$ROOT_DIR/check-updates.sh"

# Exercise the actual formatter with both complete and partial splits.
awk '/^PRINT_UPDATE_SPLIT\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/formatter.sh"
source "$WORK_DIR/formatter.sh"
[[ "$(PRINT_UPDATE_SPLIT 51 28)" == $'Normal updates: 51\nSecurity updates: 28' ]]
[[ "$(PRINT_UPDATE_SPLIT 36 0)" == $'Normal updates: 36\nSecurity updates: 0' ]]
[[ "$(PRINT_UPDATE_SPLIT 1 Unknown)" == $'Normal updates: 1\nSecurity updates: Unknown' ]]
[[ "$(PRINT_UPDATE_SPLIT '' '')" == $'Normal updates: Unknown\nSecurity updates: Unknown' ]]

printf '%s\n' 'VM status output regression tests: PASS'
