#!/bin/bash

#################
# Check Updates #
#################

# shellcheck disable=SC2034

VERSION="1.7.3"

#Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"

# Tag helper (if installed)
# shellcheck disable=SC1091
if [[ -f "$LOCAL_FILES/tag-filter.sh" ]]; then . "$LOCAL_FILES/tag-filter.sh"; fi

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

ARGUMENTS () {
  local ARGUMENT
  while [ $# -gt 0 ]; do
    ARGUMENT="$1"
    case "$ARGUMENT" in
      -c)
        RICM=true
        ;;
      -u)
        RDU=true
        ;;
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
  WITH_HOST=$(awk -F'"' '/^CHECK_WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  RUNNING_VM=$(awk -F'"' '/^CHECK_RUNNING_VM=/ {print $2}' $CONFIG_FILE)
  STOPPED_VM=$(awk -F'"' '/^CHECK_STOPPED_VM=/ {print $2}' $CONFIG_FILE)
  PAUSED_VM=$(awk -F'"' '/^CHECK_PAUSED_VM=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  CHECK_URL=$(awk -F '"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' $CONFIG_FILE)
  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    apply_only_exclude_tags ONLY EXCLUDED
  fi
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
  HOST=$1
  ssh "$HOST" -p "$SSH_PORT" mkdir -p $LOCAL_FILES
  scp $LOCAL_FILES/update.conf "$HOST":$LOCAL_FILES/update.conf >/dev/null 2>&1
  ssh "$HOST" -p "$SSH_PORT" 'bash -s' < "$0" -- "-c host"
}

CHECK_HOST_ITSELF () {
  apt-get update >/dev/null 2>&1
  SECURITY_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst.*security" | tr -d '\n')
  NORMAL_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst." | tr -d '\n')
  if [[ -f /var/run/reboot-required.pkgs ]]; then REBOOT_REQUIRED=true; fi
  if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 || $REBOOT_REQUIRED == true ]]; then
    echo -e "${GN}Host${CL} : ${GN}$HOSTNAME${CL}"
  fi
  if [[ $REBOOT_REQUIRED == true ]]; then echo -e "${OR} Reboot required${CL}"; fi
  if [[ $SECURITY_APT_UPDATES != 0 && $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
  elif [[ $SECURITY_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / "
  elif [[ $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "N: $NORMAL_APT_UPDATES"
  fi
}

## Container ##
# Container Check Start
CONTAINER_CHECK_START () {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  if ! [[ -d $LOCAL_FILES/temp/ ]]; then mkdir $LOCAL_FILES/temp/; fi
  for CONTAINER in $CONTAINERS; do
    if [[ "$ONLY" == "" ]] && [[ "$EXCLUDED" =~ $CONTAINER ]]; then
      continue
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $CONTAINER ]]; then
      continue
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED" == true ]]; then
        # Start the container
        pct start "$CONTAINER"
        sleep 5
        CHECK_CONTAINER "$CONTAINER"
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
  pct config "$CONTAINER" > $LOCAL_FILES/temp/temp
  OS=$(awk '/^ostype/' $LOCAL_FILES/temp/temp | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    pct exec "$CONTAINER" -- bash -c "apt-get update" >/dev/null 2>&1
    SECURITY_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'")
    NORMAL_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'")
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
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ archlinux ]]; then
    pct exec "$CONTAINER" -- bash -c "pacman -Syu" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "pacman -Qu | wc -l")
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ "$OS" =~ alpine ]]; then
    pct exec "$CONTAINER" -- ash -c "apk update" >/dev/null 2>&1
  else
    pct exec "$CONTAINER" -- bash -c "yum update" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "yum -q check-update | wc -l")
    if [[ "$UPDATES" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  fi
}

## VM ##
# VM Check Start
VM_CHECK_START () {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through VMs
  for VM in $VMS; do
    # Check if connection is available
    if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 ]] || [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
      # Check VM
      PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
      if [[ "$ONLY" == "" && "$EXCLUDED" =~ $VM ]]; then
        continue
      elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $VM ]]; then
        continue
      elif [[ "$PRE_OS" =~ w ]]; then
        continue
      else
        STATUS=$(qm status "$VM")
        if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
          # Check suspend mode
          if [[ $(qm config "$VM" | grep 'lock:' | sed 's/lock:\s*//') == "suspend" ]]; then 
            SUSPEND=true
            echo -e "${OR}skip suspend VM${CL}"
            continue
          fi
          # Start VM
          qm start "$VM" >/dev/null 2>&1
          sleep 45
          CHECK_VM "$VM"
          # Stop/Suspend VM
          qm stop "$VM"
          SUSPEND=
        elif [[ "$STATUS" == "status: paused" && "$PAUSED_VM" == true ]]; then
          # Start VM
          qm resume "$VM" >/dev/null 2>&1
          sleep 45
          CHECK_VM "$VM"
          # Suspend VM
          qm suspend "$VM"
        elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
          CHECK_VM "$VM"
        fi
      fi
    fi
  done
}

# VM Check
CHECK_VM () {
  if [[ "$RDU" != true ]]; then
    VM=$1
  else
    VM=$(awk -F'"' '/^VM=/ {print $2}' $LOCAL_FILES/temp/var)
  fi
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  if [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    if ! (ssh "$IP" exit) >/dev/null 2>&1; then
      CHECK_VM_QEMU
    else
      OS_BASE=$(qm config "$VM" | grep ostype || true)
      if [[ "$OS_BASE" =~ l2 ]]; then
        KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
        OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" hostnamectl 2>/dev/null | grep System || true)
#        if [[ "$KERNEL" =~ FreeBSD ]]; then
#          ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg update
#          return
#        fi
        if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
          ssh "$IP" "apt-get update" >/dev/null 2>&1
          SECURITY_APT_UPDATES=$(ssh "$IP" "apt-get -s upgrade | grep -ci ^inst.*security")
          NORMAL_APT_UPDATES=$(ssh "$IP" "apt-get -s upgrade | grep -ci ^inst.")
          if ssh "$IP" stat /var/run/reboot-required.pkgs \> /dev/null 2\>\&1; then REBOOT_REQUIRED=true; fi
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
        elif [[ "$OS" =~ Fedora ]]; then
          ssh "$IP" "dnf -y update" >/dev/null 2>&1
          UPDATES=$(ssh "$IP" "dnf check-update| grep -Ec ' updates$'")
          if [[ "$UPDATES" -gt 0 ]]; then
            echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
            echo -e "$UPDATES"
          fi
        elif [[ "$OS" =~ Arch ]]; then
          UPDATES=$(ssh "$IP" "pacman -Qu | wc -l")
          if [[ "$UPDATES" -gt 0 ]]; then
            echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
            echo -e "$UPDATES"
          fi
        elif [[ "$OS" =~ Alpine ]]; then
          return
        elif [[ "$OS" =~ CentOS ]]; then
          UPDATES=$(ssh "$IP" "yum -q check-update | wc -l")
          if [[ "$UPDATES" -gt 0 ]]; then
            echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
            echo -e "$UPDATES"
          fi
        fi
      fi
    fi
  else
    CHECK_VM_QEMU
  fi
}

CHECK_VM_QEMU () {
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    KERNEL=$(qm guest cmd "$VM" get-osinfo | grep kernel-version || true)
    OS=$(qm guest cmd "$VM" get-osinfo | grep name || true)
#    if [[ "$KERNEL" =~ FreeBSD ]]; then
#      qm guest exec "$VM" -- tcsh -c "pkg update"
#      return
#    fi
    if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
      qm guest exec "$VM" -- bash -c "apt-get update" >/dev/null 2>&1
      SECURITY_APT_UPDATES=$(qm guest exec "$VM" -- bash -c "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      NORMAL_APT_UPDATES=$(qm guest exec "$VM" -- bash -c "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ $(qm guest exec "$VM" -- bash -c "[ -f /var/run/reboot-required.pkgs ]" | grep exitcode) =~ 0 ]]; then REBOOT_REQUIRED=true; fi
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
    elif [[ "$OS" =~ Fedora ]]; then
      qm guest exec "$VM" -- bash -c "dnf -y update" >/dev/null 2>&1
      UPDATES=$(qm guest exec "$VM" -- bash -c "dnf check-update | grep -Ec ' updates$'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Arch ]]; then
      UPDATES=$(qm guest exec "$VM" -- bash -c "pacman -Qu | wc -l" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ "$OS" =~ Alpine ]]; then
      return
    elif [[ "$OS" =~ CentOS ]]; then
      UPDATES=$(qm guest exec "$VM" -- bash -c "yum -q check-update | wc -l" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ "$UPDATES" -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    fi
  fi
}

# Output to file
OUTPUT_TO_FILE () {
  if [[ "$RDU" != true && "$RICM" != true ]]; then
    touch $LOCAL_FILES/check-output
    exec > >(tee $LOCAL_FILES/check-output)
    # create mail output file
    touch $LOCAL_FILES/mail-output
    echo -e "Available Updates:"  > $LOCAL_FILES/mail-output
    echo -e "S = Security / N = Normal\n" >> $LOCAL_FILES/mail-output
    exec > >(tee -a $LOCAL_FILES/mail-output)
  fi
}

# Exit
# shellcheck disable=SC2329
EXIT () {
  # clean email output file
  if [[ "$RDU" != true && "$RICM" != true ]]; then
    cat "$LOCAL_FILES/mail-output" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOCAL_FILES/mail-output" >/dev/null 2>&1
    chmod 640 "$LOCAL_FILES/mail-output"
  fi
  if [[ -f "$LOCAL_FILES/mail-output" ]] && [[ $(stat -c%s "$LOCAL_FILES/mail-output") -gt 46 ]]; then
    echo "summary email send"
    mail -s "Ultimate Updater summary" "$EMAIL_USER" < "$LOCAL_FILES"/mail-output
  else
    echo "summary email not send"
    echo "No updates found during search" | mail -s "Ultimate Updater" root
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


if wget -q --spider "$CHECK_URL" >/dev/null 2>&1; then
  # Print any tag selection summary captured during config parse
  if [[ "$RICM" != true ]]; then if declare -f print_tag_log >/dev/null 2>&1; then print_tag_log; fi; fi
  ARGUMENTS "$@"
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

exit 0