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
cat > "$WORK_DIR/update-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
INTERNAL_SSH_CONFIG_FILE="$PWD/internal-ssh.conf"
TEMP_STATE_DIR="$PWD/temp"
WINDOWS_UPDATE_ENABLED=true
START_WAITING=false
LOG="$PWD/update-result"
mkdir -p "$TEMP_STATE_DIR"
REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }
MARK_PACKAGE_DATA_INVALIDATED() { return 0; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { return 0; }
AUTO_REBOOT_GUEST() { return 0; }
qm() {
  case "$1" in
    config) printf 'ostype: l26\nname: linux\n' ;;
    guest) printf 'kernel-version: 6.1\nname: Linux\n' ;;
  esac
}
VM_BACKUP() { printf 'backup\n' >> "$LOG"; return 0; }
SCRIPT_ONLY_ENABLED() { return 1; }
UPDATE_VM_QEMU() { printf 'qga-update\n' >> "$LOG"; return 1; }
RUN_SSH_COMMAND() { printf 'ssh:%s identity=%s\n' "$*" "${RUN_SSH_IDENTITY_FILE:-}" >> "$LOG"; return 0; }
ssh() { printf 'System: Linux\n'; }
ERROR() { return 1; }
EFFECTIVE_HEADLESS() { return 1; }
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
if grep -Fq 'qga-update' "$WORK_DIR/update-result"; then
  echo 'Internal SSH update unexpectedly fell back to QGA' >&2
  exit 1
fi

echo 'VM Internal SSH update selection regression: PASS'
