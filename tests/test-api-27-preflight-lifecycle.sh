#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local/scripts.d" "$WORK_DIR/temp"

# Exercise the production API guard and both production lifecycle dispatchers.
# All Proxmox commands, guest commands, backups, and update bodies are mocks.
awk '/^SCRIPT_ONLY_ENABLED \(\) \{/{copy=1} /^SCRIPT_ONLY_FILES \(\) \{/{if(copy) exit} copy{print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/api-functions.sh"
awk '/^CONTAINER_UPDATE_START \(\) \{/{copy=1} /^# Container Update$/{if(copy) exit} copy{print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/container-start.sh"
awk '/^VM_UPDATE_START \(\) \{/{copy=1} /^# Detect the Proxmox guest OS/{if(copy) exit} copy{print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/vm-start.sh"

cat > "$WORK_DIR/harness.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

KIND=$1
SCENARIO=$2
LOCAL_FILES="$PWD/local"
USER_SCRIPTS="$LOCAL_FILES/scripts.d"
TEMP_STATE_DIR="$PWD/temp"
ERROR_LOG_FILE="$PWD/error.log"
UU_API_ACTION=update
EXTRA_GLOBAL=true
EXTRA_IN_HEADLESS=true
PIHOLE=false IOBROKER=false PTERODACTYL=false OCTOPRINT=false
DOCKER_COMPOSE=false INCLUDE_HELPER_SCRIPTS=false
SINGLE_UPDATE=true ONLY=100 EXCLUDED=''
STOPPED_CONTAINER=true RUNNING_CONTAINER=true
STOPPED_VM=true RUNNING_VM=true
USE_INTERNAL_TARGET_SELECTION=false
UPDATE_FAILURE=false
mkdir -p "$TEMP_STATE_DIR"

EVENTS="$PWD/events"
: > "$EVENTS"
rm -rf "$USER_SCRIPTS/100"

ERROR() {
  UPDATE_FAILURE=true
  printf 'error:%s:%s\n' "$ERROR_CODE" "$ERROR_MSG" >> "$EVENTS"
  return 0
}
RUN_PROXMOX_COMMAND() {
  printf 'prox:%s\n' "$*" >> "$EVENTS"
  return 0
}
RUN_PCT_COMMAND() {
  printf 'pct-exec:%s\n' "$*" >> "$EVENTS"
  printf 'safe\n'
  return 0
}
RUN_QEMU_COMMAND() {
  printf 'qga:%s\n' "$*" >> "$EVENTS"
  printf 'safe\n'
  return 0
}
WAIT_FOR_BOOTUP_LXC() { printf 'lxc-wait\n' >> "$EVENTS"; return 0; }
CAPTURE_POST_UPDATE_STATUS() { printf 'capture:%s\n' "$*" >> "$EVENTS"; }
guest_id_matches() { return 1; }
QGA_CONFIG_ENABLED() { return 0; }
UPDATE_CONTAINER() { printf 'update-lxc:%s\n' "$1" >> "$EVENTS"; }
UPDATE_VM() { printf 'update-vm:%s\n' "$1" >> "$EVENTS"; }
AUTO_REBOOT_GUEST() { printf 'auto-reboot:%s\n' "$*" >> "$EVENTS"; return 0; }

pct() {
  case "$1" in
    list) printf 'VMID Status\n100\n' ;;
    config) printf 'ostype: debian\n' ;;
    status)
      if [[ "$SCENARIO" == running ]]; then
        printf 'status: running\n'
      else
        printf 'status: stopped\n'
      fi
      ;;
  esac
}
qm() {
  case "$1" in
    list) printf 'VMID\n100\n' ;;
    config)
      if [[ "$SCENARIO" == windows-safe ]]; then
        printf 'ostype: win11\nname: Windows fixture\n'
      else
        printf 'ostype: l26\nname: Linux fixture\n'
      fi
      ;;
    status)
      if [[ "$SCENARIO" == paused ]]; then
        printf 'status: paused\n'
      elif [[ "$SCENARIO" == running ]]; then
        printf 'status: running\n'
      else
        printf 'status: stopped\n'
      fi
      ;;
  esac
}

if [[ "$SCENARIO" == unavailable ]]; then
  PIHOLE=true
elif [[ "$SCENARIO" == unsafe ]]; then
  mkdir -p "$USER_SCRIPTS/100"
  touch "$USER_SCRIPTS/100/.script-only"
elif [[ "$SCENARIO" == normal ]]; then
  unset UU_API_ACTION
  PIHOLE=true
fi

source "$PWD/api-functions.sh"
source "$PWD/container-start.sh"
source "$PWD/vm-start.sh"

if [[ "$KIND" == lxc ]]; then
  CONTAINER_UPDATE_START
else
  VM_UPDATE_START
fi

printf 'failure=%s\n' "$UPDATE_FAILURE" >> "$EVENTS"
printf 'error_code=%s\n' "${ERROR_CODE:-}" >> "$EVENTS"
EOF
chmod 750 "$WORK_DIR/harness.sh"

run_case() {
  local kind=$1 scenario=$2
  (cd "$WORK_DIR" && bash harness.sh "$kind" "$scenario")
}

# A stopped LXC with an optional guest path cannot be inspected while stopped.
run_case lxc unavailable
grep -Fxq 'failure=true' "$WORK_DIR/events"
grep -Fq 'error:43:API_PREFLIGHT_UNAVAILABLE:' "$WORK_DIR/events"
if grep -Eq 'prox:pct start|update-lxc:' "$WORK_DIR/events"; then
  echo 'stopped LXC was mutated before API preflight completed' >&2
  exit 1
fi
if grep -Fq 'pct-exec:' "$WORK_DIR/events"; then
  echo 'stopped LXC attempted a guest probe before its start decision' >&2
  exit 1
fi

# A known script-only path is unsafe, not merely unavailable.
run_case lxc unsafe
grep -Fq 'error:42:API_UNSAFE_SCRIPT_PATH:' "$WORK_DIR/events"
if grep -Eq 'prox:pct start|update-lxc:' "$WORK_DIR/events"; then
  echo 'unsafe stopped LXC was mutated before rejection' >&2
  exit 1
fi

# With optional paths disabled, a stopped LXC retains normal lifecycle behavior.
run_case lxc safe
grep -Fq 'prox:pct start 100' "$WORK_DIR/events"
grep -Fq 'update-lxc:100' "$WORK_DIR/events"
grep -Fq 'prox:pct shutdown 100' "$WORK_DIR/events"

# Normal (non-API) updates do not inherit the API-only preflight restriction.
run_case lxc normal
grep -Fq 'prox:pct start 100' "$WORK_DIR/events"
grep -Fq 'update-lxc:100' "$WORK_DIR/events"

# A running LXC is still handled by the existing API update path.
run_case lxc running
grep -Fq 'update-lxc:100' "$WORK_DIR/events"
if grep -Fq 'prox:pct start' "$WORK_DIR/events"; then
  echo 'running LXC was started again' >&2
  exit 1
fi

# The same fail-closed rule applies before a stopped Linux VM is started.
run_case vm unavailable
grep -Fxq 'failure=true' "$WORK_DIR/events"
grep -Fq 'error:43:API_PREFLIGHT_UNAVAILABLE:' "$WORK_DIR/events"
if grep -Eq 'prox:qm start|update-vm:' "$WORK_DIR/events"; then
  echo 'stopped VM was mutated before API preflight completed' >&2
  exit 1
fi

# Windows is QGA-native and has no Linux optional-script probe to perform.
run_case vm windows-safe
grep -Fq 'prox:qm start 100' "$WORK_DIR/events"
grep -Fq 'update-vm:100' "$WORK_DIR/events"
if grep -Fq 'qga:' "$WORK_DIR/events"; then
  echo 'stopped Windows VM performed a guest probe before start' >&2
  exit 1
fi

# A running VM continues through the existing update dispatcher.
run_case vm running
grep -Fq 'update-vm:100' "$WORK_DIR/events"
if grep -Fq 'prox:qm start' "$WORK_DIR/events"; then
  echo 'running VM was started again' >&2
  exit 1
fi

# A regular stopped VM update is not subject to API-only preflight policy.
run_case vm normal
grep -Fq 'prox:qm start 100' "$WORK_DIR/events"
grep -Fq 'update-vm:100' "$WORK_DIR/events"

# A paused VM is not resumed or otherwise mutated by the update dispatcher.
run_case vm paused
if grep -Eq 'prox:qm (start|resume|reboot|shutdown|reset)|update-vm:' "$WORK_DIR/events"; then
  echo 'paused VM lifecycle changed unexpectedly' >&2
  exit 1
fi

echo 'API-2.7 preflight lifecycle tests: PASS'
