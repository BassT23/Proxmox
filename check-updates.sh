#!/bin/bash

#################
# Check Updates #
#################

# shellcheck disable=SC2034

VERSION="2.1"

#Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"

TARGET_RUNTIME_FILE="${TARGET_RUNTIME_FILE:-$LOCAL_FILES/target-runtime.sh}"
if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$TARGET_RUNTIME_FILE"
else
  # These indirect transport calls are used by the legacy-compatible paths
  # below when an older installation has no shared runtime helper yet.
  # shellcheck disable=SC2317
  RUN_LOCAL_COMMAND() { "$@"; }
  RUN_PCT_COMMAND() { local target_id="$1"; shift; pct exec "$target_id" -- "$@"; }
  RUN_SSH_COMMAND() { local host="$1" port="$2" user="$3"; shift 3; ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"; }
  READ_APT_UPDATE_COUNTS() {
    SECURITY_APT_UPDATES=$(printf '%s\n' "$1" | grep -ci '^inst.*security' || true)
    NORMAL_APT_UPDATES=$(printf '%s\n' "$1" | grep -ci '^inst.' || true)
  }
fi

# Optional additive machine-readable status output. Older installations can
# continue without the helper until their next updater update.
if [[ -f "$LOCAL_FILES/status-model.sh" ]]; then
  # shellcheck disable=SC1091
  . "$LOCAL_FILES/status-model.sh"
else
  STATUS_MODEL_INIT() { :; }
  STATUS_MODEL_RECORD() { :; }
  STATUS_MODEL_FINISH() { :; }
fi

# Tag filter
TAG_FILTER_FILE="${TAG_FILTER_FILE:-$LOCAL_FILES/tag-filter.sh}"
# shellcheck disable=SC1090,SC1091
. "$TAG_FILTER_FILE"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

SANITIZE_NUMBER() {
  echo "$1" | tr -cd '0-9'
}

# Decode one structured qm guest exec response without losing the guest
# exitcode. The qm CLI itself can return zero when only the guest command
# failed, so transport and guest status are kept separate.
QEMU_GUEST_EXEC () {
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=""
  QEMU_EXEC_TRANSPORT_RC=0
  local QEMU_RAW QEMU_PARSED QEMU_STATUS

  QEMU_RAW=$(qm guest exec "$@" 2>&1)
  QEMU_STATUS=$?
  if [[ $QEMU_STATUS -ne 0 ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=$QEMU_STATUS
    return 0
  fi

  if ! QEMU_PARSED=$(printf '%s' "$QEMU_RAW" | python3 -c '
import base64
import json
import sys

try:
    response = json.load(sys.stdin)
except (TypeError, ValueError):
    sys.exit(1)

for key in ("out-data", "err-data"):
    value = response.get(key, "")
    if not isinstance(value, str):
        value = str(value)
    print(base64.b64encode(value.encode()).decode())

exitcode = response.get("exitcode", 0)
if not isinstance(exitcode, int) or exitcode < 0:
    sys.exit(1)
print(exitcode)
'); then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi

  local -a QEMU_FIELDS
  mapfile -t QEMU_FIELDS <<< "$QEMU_PARSED"
  if [[ ${#QEMU_FIELDS[@]} -ne 3 || ! ${QEMU_FIELDS[2]} =~ ^[0-9]+$ ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi
  IFS= read -r -d '' QEMU_EXEC_STDOUT < <(printf '%s' "${QEMU_FIELDS[0]}" | base64 -d) || true
  IFS= read -r -d '' QEMU_EXEC_STDERR < <(printf '%s' "${QEMU_FIELDS[1]}" | base64 -d) || true
  QEMU_EXEC_EXITCODE=${QEMU_FIELDS[2]}
  if [[ -n "$QEMU_EXEC_STDOUT" && -n "$QEMU_EXEC_STDERR" ]]; then
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}
${QEMU_EXEC_STDERR}"
  else
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}${QEMU_EXEC_STDERR}"
  fi
  return 0
}

QEMU_COUNT_RESULT_OK () {
  local QEMU_COUNT_LABEL="$1"
  local QEMU_COUNT_ZERO=false
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    echo -e "${RD}${QEMU_COUNT_LABEL} failed: ${QEMU_EXEC_OUTPUT}${CL}"
    return 1
  fi
  # grep -c returns 1 for zero matches. That is the only non-zero guest
  # status accepted for numeric update-count commands; all other failures
  # must remain visible instead of being treated as zero updates.
  if [[ "$QEMU_EXEC_EXITCODE" -eq 1 && "$QEMU_EXEC_STDOUT" =~ ^[[:space:]]*0[[:space:]]*$ && -z "$QEMU_EXEC_STDERR" ]]; then
    QEMU_COUNT_ZERO=true
  fi
  if [[ "$QEMU_EXEC_EXITCODE" -ne 0 && "$QEMU_COUNT_ZERO" != true ]]; then
    echo -e "${RD}${QEMU_COUNT_LABEL} failed (guest exit code $QEMU_EXEC_EXITCODE): ${QEMU_EXEC_OUTPUT}${CL}"
    return 1
  fi
  return 0
}

ARGUMENTS () {
  while [[ $# -gt 0 ]]; do
    local ARGUMENT="$1"
    case "$ARGUMENT" in
      -c) RICM=true ;;
      -u) RDU=true ;;
      chost)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_HOST_ITSELF
        ;;
      ccontainer)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_CONTAINER
        ;;
      cvm)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_VM
        ;;
      host)
        COMMAND=true
        OUTPUT_TO_FILE
        if [[ "$WITH_HOST" == true ]]; then CHECK_HOST_ITSELF; fi
        if [[ "$WITH_LXC" == true ]]; then CONTAINER_CHECK_START; fi
        if [[ "$WITH_VM" == true ]]; then VM_CHECK_START; fi
        ;;
      cluster)
        COMMAND=true
        OUTPUT_TO_FILE
        HOST_CHECK_START
        ;;
      *)
        echo -e "\n${RD}  Error: Got an unexpected argument \"$ARGUMENT\"${CL}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}

# Usage
USAGE () {
  echo -e "\nUsage: $0 {COMMAND}\n"
  echo -e "{COMMAND}:"
  echo -e "========="
  echo -e "  host                 Host-Mode"
  echo -e "  cluster              Cluster-Mode\n"
  echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
}


READ_WRITE_CONFIG () {
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' $CONFIG_FILE)
  EMAIL_USER=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' $CONFIG_FILE)
  EMAIL_SENDER=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' $CONFIG_FILE)
  EMAIL_DAILY_CHECK=$(awk -F'"' '/^EMAIL_DAILY_CHECK=/ {print $2}' $CONFIG_FILE)
  EMAIL_NO_UPDATES=$(awk -F'"' '/^EMAIL_NO_UPDATES=/ {print $2}' $CONFIG_FILE)
  EMAIL_ONLY_SECURITY=$(awk -F'"' '/^EMAIL_ONLY_SECURITY=/ {print $2}' $CONFIG_FILE)
  EMAIL_USER="${EMAIL_USER:-root}"
  EMAIL_SENDER="${EMAIL_SENDER:-$USER}"
  EMAIL_DAILY_CHECK="${EMAIL_DAILY_CHECK:-true}"
  EMAIL_NO_UPDATES="${EMAIL_NO_UPDATES:-false}"
  EMAIL_ONLY_SECURITY="${EMAIL_ONLY_SECURITY:-false}"
  WITH_HOST=$(awk -F'"' '/^CHECK_WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  RUNNING_VM=$(awk -F'"' '/^CHECK_RUNNING_VM=/ {print $2}' $CONFIG_FILE)
  STOPPED_VM=$(awk -F'"' '/^CHECK_STOPPED_VM=/ {print $2}' $CONFIG_FILE)
  PAUSED_VM=$(awk -F'"' '/^CHECK_PAUSED_VM=/ {print $2}' $CONFIG_FILE)
  REBOOT_IF_NEEDED=$(awk -F'"' '/^REBOOT_IF_NEEDED=/ {print $2}' "$CONFIG_FILE")
  REBOOT_IF_NEEDED="${REBOOT_IF_NEEDED:-true}"
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  CHECK_URL=$(awk -F '"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' $CONFIG_FILE)
  LXC_START_DELAY=$(awk -F'"' '/^LXC_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  LXC_START_DELAY=$(SANITIZE_NUMBER "$LXC_START_DELAY")
  LXC_START_DELAY="${LXC_START_DELAY:-5}"
  VM_START_DELAY=$(awk -F'"' '/^VM_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  VM_START_DELAY=$(SANITIZE_NUMBER "$VM_START_DELAY")
  VM_START_DELAY="${VM_START_DELAY:-45}"

  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    apply_only_exclude_tags ONLY EXCLUDED
  fi
}

# Wait for bootup / reboot
# Container
WAIT_FOR_BOOTUP_LXC () {
  MAX_RETRIES=10
  COUNT=1
  sleep "$LXC_START_DELAY"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if pct exec "$CONTAINER" -- bash -c "exit" >/dev/null 2>&1; then
      break
    else
      sleep "$LXC_START_DELAY"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    return 1
  fi
}

WAIT_FOR_QGA () {
  local max_wait=180 interval=2
  local deadline=$((SECONDS + max_wait))
  while (( SECONDS < deadline )); do
    if qm agent "$VM" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep "$interval"
  done
  echo -e "${RD}QEMU Guest Agent did not become ready for VM $VM${CL}"
  return 1
}

## HOST ##
# Host Check Start
HOST_CHECK_START () {
  for HOST in $HOSTS; do
    CHECK_HOST "$HOST"
  done
}

# Host Check
CHECK_HOST () {
  local HOST=$1 remote_check_dir remote_status
  remote_check_dir="/tmp/ultimate-updater-check-$$"
  remote_runtime_env=""
  if ! ssh "$HOST" -p "$SSH_PORT" "mkdir -p '$LOCAL_FILES' '$remote_check_dir'" ||
    ! scp "$LOCAL_FILES/update.conf" "$HOST:$LOCAL_FILES/update.conf" >/dev/null 2>&1 ||
    ! scp "$TAG_FILTER_FILE" "$HOST:$remote_check_dir/tag-filter.sh" >/dev/null 2>&1; then
    ssh "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
    echo -e "${RD}Could not prepare matching check helper on remote host $HOST${CL}"
    STATUS_MODEL_RECORD "$HOST" host ssh false "" "" "null" "null" offline SSH_UNREACHABLE "Could not prepare remote check"
    return 1
  fi
  if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
    if ! scp "$TARGET_RUNTIME_FILE" "$HOST:$remote_check_dir/target-runtime.sh" >/dev/null 2>&1; then
      ssh "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
      echo -e "${RD}Could not prepare target runtime helper on remote host $HOST${CL}"
      STATUS_MODEL_RECORD "$HOST" host ssh false "" "" "null" "null" offline SSH_UNREACHABLE "Could not prepare remote target runtime"
      return 1
    fi
    remote_runtime_env=" TARGET_RUNTIME_FILE='$remote_check_dir/target-runtime.sh'"
  fi
  if ssh "$HOST" -p "$SSH_PORT" \
    "TAG_FILTER_FILE='$remote_check_dir/tag-filter.sh'$remote_runtime_env bash -s -- -c host" < "$0"; then
    remote_status=0
  else
    remote_status=$?
  fi
  ssh "$HOST" -p "$SSH_PORT" "rm -rf -- '$remote_check_dir'" >/dev/null 2>&1 || true
  if [[ "$remote_status" -ne 0 ]]; then
    STATUS_MODEL_RECORD "$HOST" host ssh true "" "" "null" "null" error REMOTE_CHECK_FAILED "Remote check exited with $remote_status"
  fi
  return "$remote_status"
}

CHECK_HOST_ITSELF () {
  apt-get update >/dev/null 2>&1
  SECURITY_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst.*security" | tr -d '\n')
  if [[ $SECURITY_APT_UPDATES != 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
  NORMAL_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst." | tr -d '\n')
  if [[ -f /var/run/reboot-required.pkgs ]]; then REBOOT_REQUIRED=true; fi
  if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 || $REBOOT_REQUIRED == true ]]; then
    echo -e "\n${BL}Host${CL} : ${GN}$HOSTNAME${CL}"
  fi
  if [[ $REBOOT_REQUIRED == true ]]; then echo -e "${OR} Reboot required${CL}"; fi
  if [[ $SECURITY_APT_UPDATES != 0 && $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
  elif [[ $SECURITY_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / "
  elif [[ $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "N: $NORMAL_APT_UPDATES"
  fi
  local HOST_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
  local HOST_STATUS=ok
  [[ "$HOST_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && HOST_STATUS=updates_available
  local HOST_OS
  HOST_OS=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
  STATUS_MODEL_RECORD "host:$HOSTNAME" host local true "${HOST_OS:-unknown}" apt "$HOST_UPDATES" "${REBOOT_REQUIRED:-false}" "$HOST_STATUS" "" ""
}

## Container ##
# Container Check Start
CONTAINER_CHECK_START () {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  if ! [[ -d $LOCAL_FILES/temp/ ]]; then mkdir $LOCAL_FILES/temp/; fi
  for CONTAINER in $CONTAINERS; do
    if [[ "$ONLY" == "" ]] && guest_id_matches "$EXCLUDED" "$CONTAINER"; then
      continue
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$CONTAINER"; then
      continue
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED" == true ]]; then
        # Start the container
        pct start "$CONTAINER"
        if WAIT_FOR_BOOTUP_LXC; then
          CHECK_CONTAINER "$CONTAINER"
        else
          echo -e "${RD}Skipping LXC $CONTAINER because it did not become reachable${CL}"
        fi
        # Stop the container
        pct shutdown "$CONTAINER"
      elif [[ "$STATUS" == "status: running" && "$RUNNING" == true ]]; then
        CHECK_CONTAINER "$CONTAINER"
      fi
    fi
  done
  rm -rf $LOCAL_FILES/temp/temp
}

# Container Check
CHECK_CONTAINER () {
  if [[ "$RDU" != true ]]; then
    CONTAINER=$1
  else
    CONTAINER=$(awk -F'"' '/^CONTAINER=/ {print $2}' $LOCAL_FILES/temp/var)
  fi
  local CONTAINER_UPDATES=0 CONTAINER_STATUS=ok CONTAINER_REBOOT=false
  pct config "$CONTAINER" > $LOCAL_FILES/temp/temp
  OS=$(awk '/^ostype/' $LOCAL_FILES/temp/temp | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get update" >/dev/null 2>&1
    APT_OUTPUT=$(RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get -s upgrade")
    READ_APT_UPDATE_COUNTS "$APT_OUTPUT"
    if [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
    CONTAINER_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
    if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
    fi
    if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" != 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
    elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / "
    elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
      echo -e "N: $NORMAL_APT_UPDATES"
    fi
  elif [[ "$OS" =~ fedora ]]; then
    pct exec "$CONTAINER" -- bash -c "dnf update" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "dnf check-update | grep -Ec ' updates$'")
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ archlinux ]]; then
    pct exec "$CONTAINER" -- bash -c "pacman -Syu" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "pacman -Qu | wc -l")
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ alpine ]]; then
    pct exec "$CONTAINER" -- ash -c "apk update" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- ash -c "apk list -u | wc -l")
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  else
    pct exec "$CONTAINER" -- bash -c "yum update" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "yum -q check-update | wc -l")
    CONTAINER_UPDATES=$(SANITIZE_NUMBER "$UPDATES")
    CONTAINER_UPDATES=${CONTAINER_UPDATES:-0}
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  fi
  [[ "$CONTAINER_UPDATES" -gt 0 ]] && CONTAINER_STATUS=updates_available
  STATUS_MODEL_RECORD "$CONTAINER" lxc pct true "$OS" "${OS,,}" "$CONTAINER_UPDATES" "$CONTAINER_REBOOT" "$CONTAINER_STATUS" "" ""
}

## VM ##
# VM Check Start
VM_CHECK_START () {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through VMs
  for VM in $VMS; do
    REBOOT_REQUIRED=false
    SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "${VM_START_DELAY:-45}")
    SSH_START_DELAY_TIME=${SSH_START_DELAY_TIME:-45}
    # Check if connection is available
    if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 ]] || [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
      # Check VM
      PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
      if [[ "$ONLY" == "" ]] && guest_id_matches "$EXCLUDED" "$VM"; then
        continue
      elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$VM"; then
        continue
      elif [[ "$PRE_OS" =~ w ]]; then
        continue
      else
        STATUS=$(qm status "$VM")
        if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
          IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          USER="${USER:-root}"
          SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          SSH_VM_PORT="${SSH_VM_PORT:-22}"
          SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
          SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "$SSH_START_DELAY_TIME")
          SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-$VM_START_DELAY}"
        fi
        if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
          # Check suspend mode
          if [[ $(qm config "$VM" | grep 'lock:' | sed 's/lock:\s*//') == "suspend" ]]; then 
            SUSPEND=true
            echo -e "${OR}skip suspend VM${CL}"
            continue
          fi
          # Start VM
          qm start "$VM" >/dev/null 2>&1
          if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
            sleep "$SSH_START_DELAY_TIME"
            CHECK_VM "$VM"
          elif WAIT_FOR_QGA; then
            CHECK_VM "$VM"
          else
            echo -e "${RD}Skipping VM $VM because QEMU Guest Agent is not ready${CL}"
            STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" offline QGA_NOT_READY "QEMU Guest Agent was not ready"
          fi
          # Stop/Suspend VM
          qm stop "$VM"
          SUSPEND=
        elif [[ "$STATUS" == "status: paused" && "$PAUSED_VM" == true ]]; then
          # Start VM
          qm resume "$VM" >/dev/null 2>&1
          sleep "$SSH_START_DELAY_TIME"
          CHECK_VM "$VM"
          # Suspend VM
          qm suspend "$VM"
        elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
          VM_NOT_STOPPED=true
          CHECK_VM "$VM"
          VM_NOT_STOPPED=""
        fi
      fi
    fi
  done
}

# VM Check
CHECK_VM () {
  local IP USER SSH_VM_PORT SSH_START_DELAY_TIME
  if [[ "$RDU" != true ]]; then
    VM=$1
  else
    VM=$(awk -F'"' '/^VM=/ {print $2}' $LOCAL_FILES/temp/var)
  fi
  if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_START_DELAY_TIME=$(SANITIZE_NUMBER "$SSH_START_DELAY_TIME")
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-$VM_START_DELAY}"
  fi
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  if [[ -z "$IP" || -z "$USER" || -z "$SSH_VM_PORT" ]]; then
    CHECK_VM_QEMU
    return
  fi
  if ! RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "true" >/dev/null 2>&1; then
    CHECK_VM_QEMU
    return
  fi
  OS_BASE=$(qm config "$VM" | grep ostype || true)
  if [[ "$OS_BASE" =~ l2 ]]; then
    KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
    OS=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" hostnamectl 2>/dev/null | grep System || true)
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "apt-get update" >/dev/null 2>&1
      APT_OUTPUT=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "apt-get -s upgrade")
      READ_APT_UPDATE_COUNTS "$APT_OUTPUT"
      if ssh -q -p "$SSH_VM_PORT" "$USER@$IP" stat /var/run/reboot-required.pkgs \> /dev/null 2\>\&1; then
        REBOOT_REQUIRED=true
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${OR} Reboot required${CL}"
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
      elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / "
      elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "N: $NORMAL_APT_UPDATES"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]] && [[ "$REBOOT_IF_NEEDED" == true ]] && [[ "$VM_NOT_STOPPED" == true ]]; then
        ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "reboot" >/dev/null 2>&1
      fi
    elif [[ "$OS" =~ Fedora ]]; then
      ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "dnf -y update" >/dev/null 2>&1
      UPDATES=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "dnf check-update | grep -Ec ' updates$'")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Arch ]]; then
      UPDATES=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "pacman -Qu | wc -l")
      UPDATES=${UPDATES//[^0-9]/}
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Alpine ]]; then
      UPDATES=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "apk list -u | wc -l")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ CentOS ]]; then
      UPDATES=$(ssh -q -p "$SSH_VM_PORT" "$USER@$IP" "yum -q check-update | wc -l")
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    fi
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      SSH_MODEL_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
      SSH_MODEL_STATUS=ok
      [[ "$SSH_MODEL_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && SSH_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" apt "$SSH_MODEL_UPDATES" "${REBOOT_REQUIRED:-false}" "$SSH_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ fedora ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" dnf "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ arch ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" pacman "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ alpine ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" apk "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    elif [[ ${OS,,} =~ centos ]]; then
      STATUS_MODEL_STATUS=ok
      [[ "${UPDATES:-0}" -gt 0 ]] && STATUS_MODEL_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" yum "${UPDATES:-0}" false "$STATUS_MODEL_STATUS" "" ""
    else
      STATUS_MODEL_RECORD "$VM" vm ssh true "$OS" "" "null" "null" unsupported UNSUPPORTED_OS "No supported updater detected"
    fi
  fi
}

CHECK_VM_QEMU () {
  QEMU_GUEST_EXEC "$VM" test
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga false "" "" "null" "null" error QGA_TRANSPORT "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  if [[ "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    STATUS_MODEL_RECORD "$VM" vm qga true "" "" "null" "null" error QGA_GUEST_EXEC "${QEMU_EXEC_OUTPUT}"
    return 1
  fi
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]; then
    KERNEL=$(qm guest cmd "$VM" get-osinfo | grep kernel-version || true)
    OS=$(qm guest cmd "$VM" get-osinfo | grep name || true)
#    if [[ "$KERNEL" =~ FreeBSD ]]; then
#      qm guest exec "$VM" -- tcsh -c "pkg update"
#      return
#    fi
    if [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "apt-get update"
      if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
        echo -e "${RD}QEMU apt update failed for VM $VM: ${QEMU_EXEC_OUTPUT}${CL}"
        return 1
      fi
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "apt-get -s upgrade | grep -ci '^inst.*security'"
      QEMU_COUNT_RESULT_OK "QEMU security update check for VM $VM" || return 1
      SECURITY_APT_UPDATES="$QEMU_EXEC_STDOUT"
      SECURITY_APT_UPDATES=$(SANITIZE_NUMBER "$SECURITY_APT_UPDATES")
      SECURITY_APT_UPDATES=${SECURITY_APT_UPDATES:-0}
      if [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then SECURITY_UPDATES_AVALABLE=true; fi
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "apt-get -s upgrade | grep -ci '^inst.'"
      QEMU_COUNT_RESULT_OK "QEMU update check for VM $VM" || return 1
      NORMAL_APT_UPDATES="$QEMU_EXEC_STDOUT"
      NORMAL_APT_UPDATES=$(SANITIZE_NUMBER "$NORMAL_APT_UPDATES")
      NORMAL_APT_UPDATES=${NORMAL_APT_UPDATES:-0}
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c '[ -f /var/run/reboot-required.pkgs ]'
      if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
        echo -e "${RD}QEMU reboot check failed for VM $VM: ${QEMU_EXEC_OUTPUT}${CL}"
        return 1
      fi
      EXITCODE=$QEMU_EXEC_EXITCODE
      EXITCODE=${EXITCODE:-1}
      if [[ "$EXITCODE" -eq 0 ]]; then
        REBOOT_REQUIRED=true
      fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 || "$NORMAL_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
      fi
      if [[ "$REBOOT_REQUIRED" == true ]]; then echo -e "${OR} Reboot required${CL}"; fi
      if [[ "$SECURITY_APT_UPDATES" -gt 0 && "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
      elif [[ "$SECURITY_APT_UPDATES" -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / "
      elif [[ "$NORMAL_APT_UPDATES" -gt 0 ]]; then
        echo -e "N: $NORMAL_APT_UPDATES"
      fi
      QEMU_APT_UPDATES=$((SECURITY_APT_UPDATES + NORMAL_APT_UPDATES))
      QEMU_APT_STATUS=ok
      [[ "$QEMU_APT_UPDATES" -gt 0 || "$REBOOT_REQUIRED" == true ]] && QEMU_APT_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" apt "$QEMU_APT_UPDATES" "$REBOOT_REQUIRED" "$QEMU_APT_STATUS" "" ""
    elif [[ "$OS" =~ Fedora ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "dnf -y update"
      if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
        echo -e "${RD}QEMU dnf update failed for VM $VM: ${QEMU_EXEC_OUTPUT}${CL}"
        return 1
      fi
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "dnf check-update | grep -Ec ' updates$'"
      QEMU_COUNT_RESULT_OK "QEMU dnf check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_DNF_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_DNF_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" dnf "$UPDATES" false "$QEMU_DNF_STATUS" "" ""
    elif [[ "$OS" =~ Arch ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "pacman -Qu | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU pacman check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_PACMAN_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_PACMAN_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" pacman "$UPDATES" false "$QEMU_PACMAN_STATUS" "" ""
    elif [[ "$OS" =~ Alpine ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- ash -c "apk list -u | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU apk check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_APK_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_APK_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" apk "$UPDATES" false "$QEMU_APK_STATUS" "" ""
    elif [[ "$OS" =~ CentOS ]]; then
      QEMU_GUEST_EXEC "$VM" --timeout 0 -- bash -c "yum -q check-update | wc -l"
      QEMU_COUNT_RESULT_OK "QEMU yum check for VM $VM" || return 1
      UPDATES="$QEMU_EXEC_STDOUT"
      UPDATES=$(SANITIZE_NUMBER "$UPDATES")
      UPDATES=${UPDATES:-0}
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
      QEMU_YUM_STATUS=ok
      [[ "$UPDATES" -gt 0 ]] && QEMU_YUM_STATUS=updates_available
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" yum "$UPDATES" false "$QEMU_YUM_STATUS" "" ""
    else
      STATUS_MODEL_RECORD "$VM" vm qga true "$OS" "" "null" "null" unsupported UNSUPPORTED_OS "No supported updater detected"
    fi
  fi
}

# Output to file
OUTPUT_TO_FILE () {
  if [[ "$RDU" != true && "$RICM" != true ]]; then
    touch $LOCAL_FILES/check-output
    exec > >(tee $LOCAL_FILES/check-output)
    touch $LOCAL_FILES/mail-output
  fi
}

# Exit
# shellcheck disable=SC2329
EXIT () {
  # Create the mail output from the completed check output.
  if [[ "$RDU" != true && "$RICM" != true ]]; then
    # Close the tee input before waiting for its final writes.
    exec 1>/dev/null
    wait
    if [[ -f "$LOCAL_FILES/check-output" ]]; then
      {
        echo -e "Available Updates:"
        echo -e "S = Security / N = Normal\n"
        sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" "$LOCAL_FILES/check-output"
      } > "$LOCAL_FILES/mail-output"
      chmod 640 "$LOCAL_FILES/mail-output"
      if [[ $(stat -c%s "$LOCAL_FILES/mail-output") -gt 46 ]]; then
        # check variable !!!
        if [[ "$EMAIL_ONLY_SECURITY" == true && "$SECURITY_UPDATES_AVALABLE" == true ]]; then
          mail -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" < "$LOCAL_FILES"/mail-output
        else
          mail -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" < "$LOCAL_FILES"/mail-output
        fi
      elif [[ "$EMAIL_NO_UPDATES" == true ]]; then
        echo "No updates found during search" | mail -r "$EMAIL_SENDER" -s "Ultimate Updater" "$EMAIL_USER"
      fi
    fi
  fi
  if declare -f STATUS_MODEL_CLEANUP >/dev/null 2>&1; then
    STATUS_MODEL_CLEANUP
  fi
}
trap EXIT EXIT

# Run

# Debug
DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' $CONFIG_FILE)
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Check Cluster Mode
if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster"
else
  MODE="Host"
fi

# Read config
READ_WRITE_CONFIG
STATUS_MODEL_ENABLED=false
if STATUS_MODEL_INIT; then
  STATUS_MODEL_ENABLED=true
fi
if wget -q --spider "$CHECK_URL" >/dev/null 2>&1; then
  ARGUMENTS "$@"
  # Print any tag selection summary captured during config parse
  if [[ "$RDU" != true && "$RICM" != true && "$TAG_OUTPUT" != false ]]; then if declare -f print_tag_log >/dev/null 2>&1; then print_tag_log; fi; fi
else
  echo -e "${OR} You are offline${CL}"
  exit 2
fi

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true && "$RDU" == true ]]; then
  OUTPUT_TO_FILE
elif [[ "$COMMAND" != true ]]; then
  OUTPUT_TO_FILE
  if [[ "$MODE" =~ Cluster ]]; then HOST_CHECK_START; else
    if [[ "$WITH_HOST" == true ]]; then CHECK_HOST_ITSELF; fi
    if [[ "$WITH_LXC" == true ]]; then CONTAINER_CHECK_START; fi
    if [[ "$WITH_VM" == true ]]; then VM_CHECK_START; fi
  fi
fi

# Refresh the local MOTD version cache without making the login path depend on GitHub.
UPDATE_VERSION_CACHE >/dev/null 2>&1 || true
if [[ "$STATUS_MODEL_ENABLED" == true ]]; then
  STATUS_MODEL_FINISH >/dev/null 2>&1 || true
fi

exit 0
