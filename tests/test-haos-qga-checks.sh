#!/bin/bash
# shellcheck disable=SC1091
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

# A malformed get-osinfo payload must not trigger the HAOS handler merely
# because it contains an id-like text fragment.
awk '
  /^CHECK_VM_QEMU \(\) \{/ {copy=1}
  /^HAOS_PARSE_UPDATE_INFO \(\) \{/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/qga-function.sh"
cat > "$WORK_DIR/invalid-osinfo-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
VM=224
NAME=invalid-osinfo
INITIAL_INVENTORY=true
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=invalid-osinfo
HOSTNAME=test-node
LOG="$PWD/invalid-osinfo.log"
GN='' BL='' CL='' OR='' RD=''
timeout() { shift; "$@"; }
qm() {
  case "$1" in
    agent) return 0 ;;
    guest) printf '%s' '{"broken":true,"id":"haos"' ;;
  esac
}
STATUS_MODEL_RECORD() { printf '%s\n' "$*" > "$LOG"; }
CHECK_VM_QEMU_HAOS() { echo 'HAOS handler must not run for invalid JSON' >&2; return 1; }
source "$PWD/qga-function.sh"
CHECK_VM_QEMU
grep -Fq 'UNSUPPORTED_GUEST_OS' "$LOG"
HARNESS
chmod 750 "$WORK_DIR/invalid-osinfo-harness.sh"
(cd "$WORK_DIR"; bash invalid-osinfo-harness.sh)

# The HA CLI parser accepts only the documented JSON shape and real booleans.
source "$WORK_DIR/haos-functions.sh"
[[ "$(printf '  {\"result\":\"ok\",\"data\":{\"version\":\"18.2\",\"update_available\":true}}  \n' | HAOS_PARSE_UPDATE_INFO)" == $'18.2\ttrue' ]]
for invalid in \
  '{"result":"error","data":{}}' \
  '{"result":"ok"}' \
  '{"result":"ok","data":{"update_available":false}}' \
  '{"result":"ok","data":{"version":"18.2"}}' \
  '{"result":"ok","data":{"version":"18.2","update_available":"false"}}' \
  'not-json'; do
  if printf '%s' "$invalid" | HAOS_PARSE_UPDATE_INFO >/dev/null; then
    echo "Invalid HAOS response was accepted: $invalid" >&2
    exit 1
  fi
done

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
    case "$MODE" in
      core-transport) QEMU_EXEC_TRANSPORT_RC=1; QEMU_EXEC_OUTPUT='transport failure'; return ;;
      core-command) QEMU_EXEC_EXITCODE=7; QEMU_EXEC_OUTPUT='guest command failure'; return ;;
    esac
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


# Each managed component contributes exactly one total update.
: > "$LOG"
OS_UPDATE=true
CORE_UPDATE=false
MODE=ok
CHECK_VM_QEMU_HAOS
grep -Fq '|Home Assistant OS 18.2 / Core 2026.9.2|ha|1|false|updates_available|' "$LOG"

: > "$LOG"
OS_UPDATE=false
CORE_UPDATE=true
MODE=ok
CHECK_VM_QEMU_HAOS
grep -Fq '|Home Assistant OS 18.2 / Core 2026.9.2|ha|1|false|updates_available|' "$LOG"


# Core transport and guest-command failures are not partial successes.
for mode in core-transport core-command; do
  : > "$LOG"
  MODE="$mode"
  OS_UPDATE=true
  CORE_UPDATE=false
  if CHECK_VM_QEMU_HAOS; then
    echo "Expected $mode to fail" >&2
    exit 1
  fi
  grep -Fq '|Home Assistant OS 18.2|ha|null|false|error|' "$LOG"
done


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

# HAOS is total-only: no normal/security split is implied by the status model.
STATUS_MODEL_FILE="$WORK_DIR/haos-status.json" \
STATUS_MODEL_RECORD_FILE="$WORK_DIR/haos-status.records" bash -c '
  . "$1/status-model.sh"
  STATUS_MODEL_INIT
  STATUS_MODEL_RECORD 223 vm qga true "Home Assistant OS 18.2 / Core 2026.9.2" ha 2 false updates_available
  STATUS_MODEL_FINISH
' _ "$ROOT_DIR"
python3 - "$WORK_DIR/haos-status.json" <<'PY'
import json
import sys
target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updater"] == "ha"
assert target["updates"]["available"] == 2
assert target["security_split_supported"] is False
assert target["normal_updates"] is None
assert target["security_updates"] is None
PY

echo 'Home Assistant OS QGA checks: PASS'
