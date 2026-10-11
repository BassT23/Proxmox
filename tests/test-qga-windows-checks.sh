#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Windows VMs must reach UPDATE_VM_QEMU, where the QGA/PowerShell update path
# is implemented.  The former PRE_OS shortcut silently skipped them before
# QGA was even consulted.
if grep -Fq "elif [[ \"\$PRE_OS\" =~ w ]]" "$ROOT_DIR/update.sh"; then
  echo 'legacy Windows update skip is still present' >&2
  exit 1
fi
grep -Fq 'UPDATE_VM_QEMU_WINDOWS' "$ROOT_DIR/update.sh"
grep -Fq 'WINDOWS_POWERSHELL_ENCODE install-start' "$ROOT_DIR/update.sh"
grep -Fq 'WINDOWS_POWERSHELL_ENCODE install-status' "$ROOT_DIR/update.sh"
# Windows Update must not start while a previous servicing operation or a
# pending reboot is still active.  wuauserv alone is intentionally not used as
# the guard because it is commonly running while the guest is idle.
grep -Fq 'WINDOWS_POWERSHELL_ENCODE preflight' "$ROOT_DIR/update.sh"
# Process names and CPU activity are intentionally not an installation lock:
# a read-only COM search can start servicing helpers. The persistent guest
# state/mutex is the mutating-operation guard.
grep -Fq 'Global\Ultimate-Updater-WindowsUpdate' "$ROOT_DIR/windows-update.sh"
grep -Fq 'ProgramData\Ultimate-Updater\WindowsUpdate' "$ROOT_DIR/windows-update.sh"
grep -Fq "phase -in @('pending','search','download','install','unknown')" "$ROOT_DIR/windows-update.sh"
grep -Fq 'encode("utf-16le")' "$ROOT_DIR/windows-update.sh"
grep -Fq 'launcher_pid' "$ROOT_DIR/windows-update.sh"
grep -Fq 'worker_pid' "$ROOT_DIR/windows-update.sh"
grep -Fq '\$oldLauncherPid = \$null' "$ROOT_DIR/windows-update.sh"
grep -Fq '\$oldWorkerPid = \$null' "$ROOT_DIR/windows-update.sh"
grep -Fq '\$old = Get-Content -LiteralPath \$statePath -Raw | ConvertFrom-Json' "$ROOT_DIR/windows-update.sh"
grep -Fq 'worker-start-not-confirmed' "$ROOT_DIR/windows-update.sh"
grep -Fq "phase = 'unknown'" "$ROOT_DIR/windows-update.sh"
grep -Fq "UU_WINDOWS|preflight|blocked|reboot-required" "$ROOT_DIR/windows-update.sh"
grep -Fq 'UU_WINDOWS|status|' "$ROOT_DIR/windows-update.sh"
if grep -Fq 'QEMU_GUEST_EXEC_KILL_WINDOWS "$VM"' "$ROOT_DIR/update.sh"; then
  echo 'Windows update path still tries to kill a timed-out guest job' >&2
  exit 1
fi

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
QEMU_GUEST_EXEC_READONLY() { QEMU_GUEST_EXEC "$@"; }

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
QEMU_GUEST_EXEC_READONLY() { QEMU_GUEST_EXEC "$@"; }

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

# The mutating command is short and detached; status is the only operation
# repeated after launch. These contracts protect against QGA loss and replay.
grep -Fq 'Start-Process powershell.exe' "$ROOT_DIR/windows-update.sh"
grep -Fq 'Move-Item -LiteralPath' "$ROOT_DIR/windows-update.sh"
grep -Fq 'start|existing' "$ROOT_DIR/windows-update.sh"
grep -Fq 'start|existing-active' "$ROOT_DIR/windows-update.sh"
if grep -Fq 'Start-Job' "$ROOT_DIR/windows-update.sh"; then
  echo 'Windows update still uses controller-bound Start-Job' >&2
  exit 1
fi

# ------------------------------------------------------------------
# Windows update lifecycle: a status timeout must not replay the mutation.
# ------------------------------------------------------------------

awk '/^UPDATE_VM_QEMU_WINDOWS \(\) \{/{copy=1} /^## General ##/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/windows-update-function.sh"
cat > "$WORK_DIR/windows-update-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
VM=986
OR='' RD='' CL=''
ERROR_COUNT=0
STATUS_RESULT=''
ERROR() { ERROR_COUNT=$((ERROR_COUNT + 1)); }
STATUS_MODEL_UPDATE_RESULT() { STATUS_RESULT="$*"; }
WINDOWS_POWERSHELL_ENCODE() { printf '%s %s' "$1" "${2:-}"; }
QEMU_GUEST_EXEC() {
  local command=''
  local arg
  for arg in "$@"; do command+=" $arg"; done
  QEMU_EXEC_STDERR=''; QEMU_EXEC_OUTPUT=''; QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_TRANSPORT_RC=0; QEMU_EXEC_ERROR_CLASS=''
  if [[ "$command" == *'preflight'* ]]; then
    QEMU_EXEC_STDOUT='UU_WINDOWS|preflight|ok|ready'
  elif [[ "$command" == *'install-start'* ]]; then
    local job_id=${command##*install-start }
    QEMU_EXEC_STDOUT="UU_WINDOWS|start|started|$job_id|1234"
  else
    QEMU_EXEC_STDOUT=''
    QEMU_EXEC_TRANSPORT_RC=1
    QEMU_EXEC_ERROR_CLASS=QGA_TIMEOUT
    QEMU_EXEC_OUTPUT='simulated status timeout'
  fi
}
QEMU_GUEST_EXEC_READONLY() { QEMU_GUEST_EXEC "$@"; }
source "$PWD/windows-update-function.sh"
UPDATE_VM_QEMU_WINDOWS || true
[[ "$ERROR_COUNT" == 1 ]]
[[ "$STATUS_RESULT" == '986 failed 1' ]]
HARNESS
chmod 750 "$WORK_DIR/windows-update-harness.sh"
(cd "$WORK_DIR" && bash windows-update-harness.sh)

echo 'QGA and Windows check regression tests: PASS'
