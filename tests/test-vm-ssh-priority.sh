#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ROOT_DIR/internal-ssh.sh" "$WORK_DIR/internal-ssh.sh"

cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:100]
host=192.0.2.100
user=root
port=22
enabled=true
EOF

# The inventory selector must include a VM that is configured only in the new
# internal SSH file, even when its QGA flag is absent.
awk '/^VM_CHECK_START \(\) \{/{copy=1} /^# VM Check$/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/vm-start.sh"
cat > "$WORK_DIR/selector-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
ONLY="" EXCLUDED="" INITIAL_INVENTORY=true
STOPPED_VM=false PAUSED_VM=false RUNNING_VM=true VM_START_DELAY=0
STATUS_MODEL_NODE=test-node STATUS_MODEL_GUEST_NAME=""
SANITIZE_NUMBER() { printf '%s' "$1"; }
guest_id_matches() { return 1; }
qm() {
  case "$1" in
    list) printf 'VMID NAME STATUS\n100 pfsense running\n' ;;
    config) printf 'ostype: l26\nname: pfsense\n' ;;
    status) printf 'status: running\n' ;;
  esac
}
CHECK_VM() { printf 'check-vm:%s\n' "$1" > "$PWD/selector-result"; }
STATUS_MODEL_RECORD() { :; }
source "$PWD/internal-ssh.sh"
source "$PWD/vm-start.sh"
VM_CHECK_START
grep -Fxq 'check-vm:100' "$PWD/selector-result"
HARNESS
chmod 750 "$WORK_DIR/selector-harness.sh"
(cd "$WORK_DIR" && bash selector-harness.sh)

# With SSH available, CHECK_VM must not invoke the QGA fallback.  The
# FreeBSD-shaped SSH result is intentionally unsupported for package updates,
# but remains a successful, neutral initial-inventory record.
awk '/^CHECK_VM \(\) \{/{copy=1} /^CHECK_VM_QEMU \(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-vm.sh"
cat > "$WORK_DIR/ssh-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
INITIAL_INVENTORY=true RDU=false VM=100
STATUS_MODEL_NODE=test-node STATUS_MODEL_GUEST_NAME=""
LOG="$PWD/ssh-result"
SANITIZE_NUMBER() { printf '%s' "$1"; }
INTERNAL_SSH_USE_IDENTITY() { :; }
INTERNAL_SSH_RESOLVE_VM() { source "$PWD/internal-ssh.sh"; INTERNAL_SSH_RESOLVE vm "$1" "$2" "$3" "$4"; }
RUN_SSH_COMMAND() {
  printf 'ssh:%s\n' "$*" >> "$LOG"
  [[ "$4" == hostnamectl ]] && printf 'System: FreeBSD\n'
  return 0
}
GUEST_INTERNET_PREFLIGHT_SSH() { return 0; }
CHECK_VM_QEMU() { printf 'qga-called\n' >> "$LOG"; return 1; }
STATUS_MODEL_RECORD() { printf 'record:%s\n' "$*" >> "$LOG"; }
qm() {
  case "$1" in
    config) printf 'ostype: l2\nname: pfsense\n' ;;
  esac
}
source "$PWD/internal-ssh.sh"
source "$PWD/check-vm.sh"
CHECK_VM 100
grep -Fq 'ssh:192.0.2.100 22 root true' "$LOG"
grep -Fq 'record:100 vm ssh true System: FreeBSD' "$LOG"
if grep -Fq qga-called "$LOG"; then
  echo 'SSH-configured FreeBSD VM incorrectly fell back to QGA' >&2
  exit 1
fi
HARNESS
chmod 750 "$WORK_DIR/ssh-harness.sh"
(cd "$WORK_DIR" && bash ssh-harness.sh)

# With no SSH override, a reachable FreeBSD-shaped QGA must be neutral during
# initial inventory and must not run the Linux /bin/true probe.
awk '/^CHECK_VM_QEMU \(\) \{/{copy=1} /^CHECK_VM_QEMU_WINDOWS \(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-qemu.sh"
cat > "$WORK_DIR/qga-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
VM=100 INITIAL_INVENTORY=true STATUS_MODEL_NODE=test-node STATUS_MODEL_GUEST_NAME="" CONFIG_FILE=/dev/null RDU=false
LOG="$PWD/qga-result"
timeout() { shift; "$@"; }
qm() {
  case "$1" in
    agent) [[ "${QGA_FAIL:-false}" != true ]] ;;
    guest) printf 'name: FreeBSD\n' ;;
  esac
}
QEMU_GUEST_EXEC() { printf 'linux-probe-called\n' >> "$LOG"; QEMU_EXEC_TRANSPORT_RC=0; QEMU_EXEC_EXITCODE=0; }
STATUS_MODEL_RECORD() { printf 'record:%s\n' "$*" >> "$LOG"; }
source "$PWD/check-qemu.sh"
CHECK_VM_QEMU
grep -Fq 'record:100 vm qga true FreeBSD  null null not_checked UNSUPPORTED_GUEST_OS' "$LOG"
if grep -Fq linux-probe-called "$LOG"; then
  echo 'FreeBSD QGA path executed Linux guest probe' >&2
  exit 1
fi
: > "$LOG"
QGA_FAIL=true
if CHECK_VM_QEMU; then
  echo 'unreachable QGA was not reported as an error' >&2
  exit 1
fi
grep -Fq 'record:100 vm qga false' "$LOG"
grep -Fq 'QGA_TRANSPORT' "$LOG"
HARNESS
chmod 750 "$WORK_DIR/qga-harness.sh"
(cd "$WORK_DIR" && bash qga-harness.sh)

echo 'VM SSH priority and FreeBSD QGA safety tests: PASS'
