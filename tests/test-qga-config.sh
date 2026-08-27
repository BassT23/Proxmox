#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete 2>/dev/null || true; rmdir "$WORK_DIR" 2>/dev/null || true' EXIT

source "$ROOT_DIR/target-runtime.sh"

QGA_VALUE=""
qm() {
  [[ "${1:-}" == config ]] || return 1
  if [[ -n "$QGA_VALUE" ]]; then
    printf 'agent: %s\n' "$QGA_VALUE"
  fi
}

assert_enabled() {
  QGA_VALUE="$1"
  QGA_CONFIG_ENABLED 978
}

assert_disabled() {
  QGA_VALUE="$1"
  if QGA_CONFIG_ENABLED 978; then
    echo "expected disabled: ${QGA_VALUE:-missing}" >&2
    exit 1
  fi
}

assert_enabled '1'
assert_enabled '1,foo=bar'
assert_enabled '1,fstrim_cloned_disks=1,type=virtio'
assert_enabled 'enabled=1'
assert_enabled 'enabled=1,foo=bar'
assert_enabled 'enabled=1,fstrim_cloned_disks=1,type=virtio'

assert_disabled '0'
assert_disabled 'enabled=0'
assert_disabled ''
assert_disabled '10'
assert_disabled 'enabled=10'
assert_disabled 'disabled=1'
assert_disabled 'not-a-value'

QGA_VALUE='enabled=1'
if QGA_CONFIG_ENABLED not-a-vmid; then
  echo 'non-numeric VMID must be rejected' >&2
  exit 1
fi

grep -Fq 'QGA_CONFIG_ENABLED' "$ROOT_DIR/check-updates.sh"
grep -Fq 'QGA_CONFIG_ENABLED' "$ROOT_DIR/update.sh"
if grep -Fq "grep 'agent:'" "$ROOT_DIR/check-updates.sh" "$ROOT_DIR/update.sh"; then
  echo 'legacy inline agent parser remains' >&2
  exit 1
fi

echo 'QGA configuration parser tests: PASS'
