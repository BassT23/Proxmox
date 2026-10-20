#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ROOT_DIR/internal-ssh.sh" "$WORK_DIR/internal-ssh.sh"
awk '/^VM_UPDATE_START \(\) \{/{copy=1} /^# Detect the Proxmox guest OS/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/vm-update-start.sh"
awk '/^QGA_CONFIG_ENABLED\(\) \{/{copy=1} copy; copy && /^\}/{exit}' \
  "$ROOT_DIR/target-runtime.sh" > "$WORK_DIR/qga-functions.sh"

cat > "$WORK_DIR/run-selection.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
USE_INTERNAL_TARGET_SELECTION=false SINGLE_UPDATE=false ONLY='' EXCLUDED=''
RUNNING_VM=true STOPPED_VM=false
LOG="$PWD/result"
guest_id_matches() { return 1; }
TARGET_SELECTION_ALLOWS() { return 0; }
UPDATE_VM() { printf 'update:%s\n' "$1" | tee -a "$LOG"; }
RUN_PROXMOX_COMMAND() { :; }
CAPTURE_POST_UPDATE_STATUS() { :; }
qm() {
  case "$1" in
    list) printf 'VMID NAME STATUS\n200 linux running\n' ;;
    config) printf 'ostype: l26\nname: linux\n' ;;
    status) printf 'status: running\n' ;;
  esac
}
source "$PWD/internal-ssh.sh"
source "$PWD/qga-functions.sh"
source "$PWD/vm-update-start.sh"
VM_UPDATE_START
HARNESS
chmod 750 "$WORK_DIR/run-selection.sh"

cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:200]
host=192.0.2.200
user=root
port=2200
identity_file=/tmp/internal-key
enabled=true
EOF
(cd "$WORK_DIR" && bash run-selection.sh)
grep -Fxq 'update:200' "$WORK_DIR/result"

# An explicit disablement must not make a VM without QGA look reachable,
# even when a legacy profile exists.
cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:200]
host=192.0.2.200
user=root
port=2200
enabled=false
EOF
rm -f "$WORK_DIR/result"
(cd "$WORK_DIR" && bash run-selection.sh)
if [[ -e "$WORK_DIR/result" ]]; then
  echo 'disabled Internal SSH VM was incorrectly selected for update' >&2
  exit 1
fi

# The actual UPDATE_VM path must resolve an Internal-SSH-only VM even when no
# legacy VMs/<id> profile exists, including its configured user and port.
awk '/^VM_IS_WINDOWS\(\) \{/{copy=1} /^# QEMU$/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-functions.sh"
awk '/^UPDATE_VM_QEMU_WINDOWS \(\) \{/{copy=1} /^## General ##/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/windows-update-function.sh"
cat "$WORK_DIR/windows-update-function.sh" >> "$WORK_DIR/update-functions.sh"
cat > "$WORK_DIR/update-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
TEMP_STATE_DIR="$PWD/temp"
WINDOWS_UPDATE_ENABLED=true
START_WAITING=false
CHECK_URL_EXE=ping
CHECK_URL=example.invalid
LOG="$PWD/update-result"
mkdir -p "$TEMP_STATE_DIR"
REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { return 0; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { return 0; }
AUTO_REBOOT_GUEST() { return 0; }
DPKG_REPAIR_PREPARE() { return 0; }
EFFECTIVE_HEADLESS() { return 1; }
RUN_UPDATE_COMMAND() {
  printf 'update-command:%s\n' "$*" >> "$LOG"
  UPDATE_STEP_OUTPUT='fixture SSH package-manager failure'
  return 42
}
ERROR() { printf 'error:%s\n' "${ERROR_CODE:-}" >> "$LOG"; return 1; }
qm() {
  case "$1" in
    config) printf 'ostype: l26\nname: linux\n' ;;
    guest) printf 'qga-called\n' >> "$LOG"; printf 'kernel-version: 6.1\nname: Linux\n' ;;
  esac
}
VM_BACKUP() { printf 'backup\n' >> "$LOG"; return 0; }
SCRIPT_ONLY_ENABLED() { return 1; }
UPDATE_VM_QEMU() { printf 'qga-update\n' >> "$LOG"; return 1; }
RUN_SSH_COMMAND() { printf 'ssh:%s identity=%s\n' "$*" "${RUN_SSH_IDENTITY_FILE:-}" >> "$LOG"; return 0; }
ssh() { printf 'System: Debian GNU/Linux 12\n'; }
source "$PWD/internal-ssh.sh"
source "$PWD/update-functions.sh"
UPDATE_VM 200 || true
HARNESS
cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:200]
host=192.0.2.200
user=admin
port=2200
identity_file=/tmp/internal-key
enabled=true
EOF
chmod 750 "$WORK_DIR/update-harness.sh"
(cd "$WORK_DIR" && bash update-harness.sh)
grep -Fq 'ssh:192.0.2.200 2200 admin exit identity=/tmp/internal-key' "$WORK_DIR/update-result"
grep -Fq 'update-command:' "$WORK_DIR/update-result"
if grep -Fq 'qga-update' "$WORK_DIR/update-result"; then
  echo 'Internal SSH update unexpectedly fell back to QGA' >&2
  exit 1
fi
if grep -Fq 'qga-called' "$WORK_DIR/update-result"; then
  echo 'SSH-selected VM update invoked QGA after transport selection' >&2
  exit 1
fi

# A Windows VM with a successful SSH probe uses the existing PowerShell/WUA
# lifecycle through OpenSSH.  A PowerShell failure after selection is terminal
# for this run; it must not trigger a second QGA mutation attempt.
cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1

[vm:986]
host=192.0.2.986
user=admin
port=2200
identity_file=/tmp/internal-key
enabled=true
EOF
cat > "$WORK_DIR/windows-update-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
TEMP_STATE_DIR="$PWD/windows-temp"
WINDOWS_UPDATE_ENABLED=true
START_WAITING=false
VM=986
LOG="$PWD/windows-update-result"
mkdir -p "$TEMP_STATE_DIR"
declare -A UPDATE_PENDING_BEFORE=([986]=1)
CAPTURE_UPDATE_PENDING_BEFORE() { :; }
UPDATE_TARGET_CAPABILITY_GUARD() { return 0; }
REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { return 0; }
VM_BACKUP() { printf 'backup\n' >> "$LOG"; return 0; }
SCRIPT_ONLY_ENABLED() { return 1; }
DPKG_REPAIR_PREPARE() { return 0; }
STATUS_MODEL_UPDATE_RESULT() { printf 'status:%s\n' "$*" >> "$LOG"; }
ERROR() { printf 'error:%s\n' "${ERROR_CODE:-}" >> "$LOG"; return 1; }
WINDOWS_POWERSHELL_ENCODE() { printf '%s %s' "$1" "${2:-}"; }
UPDATE_VM_QEMU() { printf 'qga-update\n' >> "$LOG"; return 0; }
qm() {
  case "$1" in
    config) printf 'ostype: win10\nname: windows-ssh\n' ;;
    guest) printf 'qga-called\n' >> "$LOG" ;;
  esac
}
RUN_SSH_COMMAND() {
  local encoded_arg="${!#}"
  printf 'ssh:%s\n' "$*" >> "$LOG"
  [[ "${4:-}" == exit ]] && return 0
  case "$*" in
    *preflight*) printf 'UU_WINDOWS|preflight|ok|ready\n' ;;
    *install-start*)
      [[ "${WINDOWS_SSH_FAIL:-false}" == true ]] && return 42
      printf 'UU_WINDOWS|start|started|%s|1234\n' "${encoded_arg#install-start }" ;;
    *install-status*) printf 'UU_WINDOWS|status|%s|completed|1|true|ok|updated\n' "${encoded_arg#install-status }" ;;
    *) printf 'unexpected-powershell-command\n' >> "$LOG"; return 1 ;;
  esac
}
source "$PWD/internal-ssh.sh"
source "$PWD/update-functions.sh"
if [[ "${WINDOWS_SSH_DISABLED:-false}" == true ]]; then
  rm -f "$INTERNAL_SSH_CONFIG_FILE"
  UPDATE_VM 986 || true
  grep -Fq 'qga-update' "$LOG"
  if grep -Fq '^ssh:' "$LOG"; then
    echo 'Windows VM without SSH unexpectedly attempted an SSH probe' >&2
    exit 1
  fi
  exit 0
fi
UPDATE_VM 986 || true
grep -Fq 'UU_WINDOWS|preflight|ok|ready' "$LOG" || true
if [[ "${WINDOWS_SSH_FAIL:-false}" == true ]]; then
  grep -Fq 'error:' "$LOG"
else
  grep -Fq 'status:986 success 0' "$LOG"
fi
if grep -Fq 'qga-called' "$LOG"; then
  echo 'Windows SSH update invoked QGA after SSH selection' >&2
  exit 1
fi
HARNESS
chmod 750 "$WORK_DIR/windows-update-harness.sh"
(cd "$WORK_DIR" && bash windows-update-harness.sh)

# A selected SSH Windows update failure is not retried through QGA.
rm -f "$WORK_DIR/windows-update-result"
(cd "$WORK_DIR" && WINDOWS_SSH_FAIL=true bash windows-update-harness.sh)

# With no SSH profile at all, the existing QGA/PowerShell fallback remains
# available and is selected before any package mutation.
rm -f "$WORK_DIR/internal-ssh.conf" "$WORK_DIR/windows-update-result"
(cd "$WORK_DIR" && WINDOWS_SSH_DISABLED=true bash windows-update-harness.sh)

echo 'VM Internal SSH update selection regression: PASS'
