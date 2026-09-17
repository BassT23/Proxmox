#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract the HAOS-specific functions.
awk '
  /^HAOS_PARSE_UPDATE_INFO \(\) \{/ {copy=1}
  /^CHECK_VM_QEMU_WINDOWS \(\) \{/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/haos-functions.sh"

# Verify that CHECK_VM_QEMU dispatches HAOS before generic Linux handling.
awk '
  /^CHECK_VM_QEMU \(\) \{/ {copy=1}
  /^HAOS_PARSE_UPDATE_INFO \(\) \{/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/qga-dispatch.sh"

grep -Fq 'CHECK_VM_QEMU_HAOS' "$WORK_DIR/qga-dispatch.sh"
grep -Eq '"id".*"haos"' "$WORK_DIR/qga-dispatch.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

VM=223
NAME=homeassistant
STATUS_MODEL_NODE=pve-node5
STATUS_MODEL_GUEST_NAME=homeassistant
HOSTNAME=pve-node5

GN=''
BL=''
CL=''

OS_UPDATE=false
CORE_UPDATE=false
MODE=ok
LOG="$PWD/status.log"

PRINT_UPDATE_TOTAL() {
  :
}

STATUS_MODEL_RECORD() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" \
    > "$LOG"
}

QEMU_GUEST_EXEC() {
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_STDERR=''
  QEMU_EXEC_OUTPUT=''

  if [[ "$*" == *'/usr/bin/ha os info --raw-json'* ]]; then
    QEMU_EXEC_STDOUT=$(printf \
      '{"result":"ok","data":{"version":"18.2","version_latest":"18.2","update_available":%s}}' \
      "$OS_UPDATE")
    QEMU_EXEC_OUTPUT="$QEMU_EXEC_STDOUT"
    return
  fi

  if [[ "$*" == *'/usr/bin/ha core info --raw-json'* ]]; then
    if [[ "$MODE" == invalid-core ]]; then
      QEMU_EXEC_STDOUT='not-json'
    else
      QEMU_EXEC_STDOUT=$(printf \
        '{"result":"ok","data":{"version":"2026.9.2","version_latest":"2026.9.2","update_available":%s}}' \
        "$CORE_UPDATE")
    fi
    QEMU_EXEC_OUTPUT="$QEMU_EXEC_STDOUT"
    return
  fi

  echo "Unexpected QGA command: $*" >&2
  return 1
}

source "$PWD/haos-functions.sh"


# No updates.
: > "$LOG"
OS_UPDATE=false
CORE_UPDATE=false
MODE=ok

CHECK_VM_QEMU_HAOS

grep -Fq \
  '223|vm|qga|true|Home Assistant OS 18.2 / Core 2026.9.2|ha|0|false|ok||' \
  "$LOG"


# Both managed components have updates.
: > "$LOG"
OS_UPDATE=true
CORE_UPDATE=true
MODE=ok

CHECK_VM_QEMU_HAOS

grep -Fq \
  '223|vm|qga|true|Home Assistant OS 18.2 / Core 2026.9.2|ha|2|false|updates_available||' \
  "$LOG"


# Invalid HA Core response must be an explicit check error.
: > "$LOG"
OS_UPDATE=false
CORE_UPDATE=false
MODE=invalid-core

if CHECK_VM_QEMU_HAOS; then
  echo "Expected invalid HA Core response to fail" >&2
  exit 1
fi

grep -Fq \
  '223|vm|qga|true|Home Assistant OS 18.2|ha|null|false|error|HAOS_INVALID_RESPONSE|Invalid ha core info response' \
  "$LOG"

echo 'Home Assistant OS QGA regression tests: PASS'
HARNESS

chmod 750 "$WORK_DIR/harness.sh"
(
  cd "$WORK_DIR"
  bash harness.sh
)

echo 'Home Assistant OS QGA checks: PASS'
