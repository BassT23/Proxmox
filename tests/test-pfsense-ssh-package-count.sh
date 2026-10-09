#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/pkg" <<'SH'
#!/bin/sh
case "${PKG_FIXTURE:-updates}" in
  updates)
    printf '%s\n' \
      'miniupnpd-2.3.9_1,1                <' \
      'pfSense-repoc-20260827.172430      <' \
      'strongswan-6.0.7                   <' \
      'unbound-1.25.2                     <'
    ;;
  empty)
    :
    ;;
  invalid)
    printf '%s\n' 'pkg: unexpected diagnostic output'
    ;;
  fail)
    exit 42
    ;;
esac
SH
chmod 750 "$WORK_DIR/pkg"

run_count() {
  local fixture="$1" expected="$2" result
  result=$(PATH="$WORK_DIR:$PATH" PKG_FIXTURE="$fixture" \
    "$ROOT_DIR/package-count.sh" pkg)
  [[ "$result" == "$expected" ]]
}

run_count updates 'UU_PACKAGE_COUNTS|ok|pkg|4|null|null|false'
run_count empty 'UU_PACKAGE_COUNTS|ok|pkg|0|null|null|false'

if PATH="$WORK_DIR:$PATH" PKG_FIXTURE=invalid \
  "$ROOT_DIR/package-count.sh" pkg >/dev/null 2>&1; then
  echo 'invalid pkg output was accepted' >&2
  exit 1
fi

if PATH="$WORK_DIR:$PATH" PKG_FIXTURE=fail \
  "$ROOT_DIR/package-count.sh" pkg >/dev/null 2>&1; then
  echo 'pkg command failure was accepted' >&2
  exit 1
fi

# Exercise the SSH FreeBSD branch and verify that a package-count failure does
# not turn an already-proven SSH transport into reachable=false.
cp "$ROOT_DIR/internal-ssh.sh" "$WORK_DIR/internal-ssh.sh"
cp "$ROOT_DIR/target-runtime.sh" "$WORK_DIR/target-runtime.sh"
awk '/^CHECK_VM \(\) \{/{copy=1} /^CHECK_VM_QEMU \(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-vm.sh"
cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:100]
host=192.0.2.100
user=root
port=22
enabled=true
EOF

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
INITIAL_INVENTORY=true RDU=false VM=100
STATUS_MODEL_NODE=test-node STATUS_MODEL_GUEST_NAME=""
GN='' BL='' CL=''
LOG="$PWD/status.log"
source "$PWD/target-runtime.sh"
SANITIZE_NUMBER() { printf '%s' "$1"; }
PRINT_UPDATE_TOTAL() { :; }
PACKAGE_COUNT_REMOTE_COMMAND() { printf 'pkg-helper'; }
INTERNAL_SSH_USE_IDENTITY() { :; }
GUEST_INTERNET_PREFLIGHT_SSH() { return 0; }
RUN_SSH_COMMAND() {
  case "$4" in
    true|hostnamectl) return 0 ;;
    'uname -s') printf 'FreeBSD\n' ;;
    'uname -v') printf 'FreeBSD pfSense test\n' ;;
    pkg-helper)
      if [[ "${PACKAGE_RESULT:-fail}" == success ]]; then
        printf 'UU_PACKAGE_COUNTS|ok|pkg|4|null|null|false\n'
        return 0
      fi
      return 1
      ;;
  esac
  return 1
}
STATUS_MODEL_RECORD() { printf 'record:%s\n' "$*" > "$LOG"; }
qm() {
  case "$1" in
    config) printf 'ostype: l26\nname: pfsense\n' ;;
  esac
}
source "$PWD/internal-ssh.sh"
source "$PWD/check-vm.sh"
CHECK_VM 100 || true
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

(cd "$WORK_DIR" && PACKAGE_RESULT=fail bash harness.sh)
grep -Fq 'record:100 vm ssh true pfSense' "$WORK_DIR/status.log"
grep -Fq 'PACKAGE_COUNT_FAILED' "$WORK_DIR/status.log"

(cd "$WORK_DIR" && PACKAGE_RESULT=success bash harness.sh)
grep -Fq 'record:100 vm ssh true pfSense' "$WORK_DIR/status.log"
grep -Fq 'pkg 4 false updates_available' "$WORK_DIR/status.log"

printf '%s\n' 'pfSense SSH package-count tests: PASS'
