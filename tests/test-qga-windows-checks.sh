#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ------------------------------------------------------------------
# Windows QGA result parsing
# ------------------------------------------------------------------

awk '
  /^CHECK_VM_QEMU_WINDOWS \(\) \{/ {copy=1}
  /^# Output to file$/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/windows-function.sh"

cat > "$WORK_DIR/windows-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

VM=1000
NAME=WIN-DEV2
OS=$'   "name" : "Microsoft Windows",\n   "pretty-name" : "Windows Server 2022 Datacenter Evaluation",'
GN='' BL='' CL='' OR=''
LOG="$PWD/windows-result"

WINDOWS_POWERSHELL_ENCODE() {
  printf 'encoded-command'
}

PRINT_UPDATE_SPLIT() {
  :
}

STATUS_MODEL_RECORD() {
  printf '%s\n' "$*" >> "$LOG"
}

QEMU_GUEST_EXEC() {
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_STDERR=''
  QEMU_EXEC_STDOUT=$'PowerShell informational output\nUU_WINDOWS|ok|0|false\n'
  QEMU_EXEC_OUTPUT="$QEMU_EXEC_STDOUT"
}

source "$PWD/windows-function.sh"

CHECK_VM_QEMU_WINDOWS

grep -Fq \
  '1000 vm qga true Windows Server 2022 Datacenter Evaluation windows-update 0 false ok' \
  "$LOG"
HARNESS

chmod 750 "$WORK_DIR/windows-harness.sh"
(
  cd "$WORK_DIR"
  bash windows-harness.sh
)


# ------------------------------------------------------------------
# Generic Linux QGA OS metadata
# ------------------------------------------------------------------

awk '
  /^CHECK_VM_QEMU \(\) \{/ {copy=1}
  /^CHECK_VM_QEMU_WINDOWS \(\) \{/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/qga-function.sh"

cat > "$WORK_DIR/qga-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

VM=120
NAME=openclaw-debian
INITIAL_INVENTORY=false
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=openclaw-debian
REBOOT_REQUIRED=false
GN='' BL='' CL='' OR='' RD=''
LOG="$PWD/qga-result"

timeout() {
  shift
  "$@"
}

qm() {
  case "$1" in
    agent)
      return 0
      ;;
    guest)
      cat <<'JSON'
{
  "id": "debian",
  "name": "Debian GNU/Linux",
  "pretty-name": "Debian GNU/Linux 13 (trixie)",
  "version-id": "13"
}
JSON
      ;;
  esac
}

QEMU_GUEST_EXEC() {
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_STDERR=''
  QEMU_EXEC_STDOUT=''
  QEMU_EXEC_OUTPUT=''

  if [[ "$*" == *'/var/run/reboot-required.pkgs'* ]]; then
    QEMU_EXEC_EXITCODE=1
  else
    QEMU_EXEC_EXITCODE=0
  fi
}

GUEST_INTERNET_PREFLIGHT_QGA() {
  return 0
}

APT_COUNT_REMOTE_COMMAND() {
  printf ':'
}

PARSE_APT_UPDATE_COUNTS() {
  NORMAL_APT_UPDATES=0
  SECURITY_APT_UPDATES=0
  return 0
}

PRINT_UPDATE_SPLIT() { :; }
PRINT_UPDATE_TOTAL() { :; }

STATUS_MODEL_RECORD() {
  printf '%s\n' "$*" >> "$LOG"
}

source "$PWD/qga-function.sh"

CHECK_VM_QEMU

grep -Fq \
  '120 vm qga true Debian GNU/Linux 13 (trixie) apt 0 false ok' \
  "$LOG"
HARNESS

chmod 750 "$WORK_DIR/qga-harness.sh"
(
  cd "$WORK_DIR"
  bash qga-harness.sh
)


# ------------------------------------------------------------------
# Remote helper staging contracts
# ------------------------------------------------------------------

awk '
  /^CHECK_HOST \(\) \{/ {copy=1}
  /^CHECK_HOST_ITSELF \(\) \{/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-host.sh"

grep -Fq 'qga-guest-exec.sh' "$WORK_DIR/check-host.sh"
grep -Fq 'windows-update.sh' "$WORK_DIR/check-host.sh"
grep -Fq 'UU_QGA_EXEC_SCRIPT=' "$WORK_DIR/check-host.sh"
grep -Fq 'WINDOWS_UPDATE_FILE=' "$WORK_DIR/check-host.sh"

awk '
  /^remote_target_check\(\)/ {copy=1}
  /^remote_target_update\(\)/ {if(copy) exit}
  copy
' "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/remote-target.sh"

grep -Fq 'windows-update.sh' "$WORK_DIR/remote-target.sh"

echo 'QGA and Windows check regression tests: PASS'
