#!/bin/bash
set -euo pipefail
# Literal grep patterns intentionally contain shell syntax.
# shellcheck disable=SC2016

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# The policy is opt-in, defaults false when absent, and is enforced before
# VM_BACKUP. This fixture never invokes a Proxmox mutation or guest command.
awk '/^VM_IS_WINDOWS\(\) \{/{copy=1} /^# QEMU$/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-function.sh"
cat > "$WORK_DIR/policy-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
TEMP_STATE_DIR="$PWD/temp"
mkdir -p "$TEMP_STATE_DIR"
WINDOWS_UPDATE_ENABLED="${WINDOWS_UPDATE_ENABLED:-false}"
GN='' YL='' BL='' CL=''
BACKUP_CALLED=false
STATUS_RESULT=''
qm() {
  case "$1" in
    config) printf 'ostype: win10\nname: fixture\n' ;;
  esac
}
VM_BACKUP() { BACKUP_CALLED=true; return 0; }
STATUS_MODEL_UPDATE_RESULT() { STATUS_RESULT="$*"; }
SCRIPT_ONLY_ENABLED() { return 1; }
ERROR() { return 1; }
source "$PWD/update-function.sh"
UPDATE_VM 986
[[ "$BACKUP_CALLED" == false ]]
[[ "$STATUS_RESULT" == '986 skipped 0' ]]
HARNESS
chmod 750 "$WORK_DIR/policy-harness.sh"
(cd "$WORK_DIR" && bash policy-harness.sh)

if (cd "$WORK_DIR" && WINDOWS_UPDATE_ENABLED=true bash policy-harness.sh) 2>/dev/null; then
  echo 'policy fixture unexpectedly treated enabled mode as skipped' >&2
  exit 1
fi

grep -Fq 'WINDOWS_UPDATE_ENABLED="${WINDOWS_UPDATE_ENABLED:-false}"' "$ROOT_DIR/update.sh"
grep -Fq 'WINDOWS_UPDATE_ENABLED="false"' "$ROOT_DIR/update.conf.dist"
grep -Fq 'WINDOWS_UPDATE_ENABLED' "$ROOT_DIR/web-ui/server.py"
grep -Fq 'start_job="$job_id"' "$ROOT_DIR/update.sh"
if grep -Eq '^[[:space:]]*elif \[\[ "\$PRE_OS" =~ w \]\]; then' "$ROOT_DIR/check-updates.sh"; then
  echo 'Windows guests are still excluded from Check-All' >&2
  exit 1
fi

echo 'Windows update policy regression tests: PASS'
