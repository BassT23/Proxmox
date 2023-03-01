#!/bin/bash

VERSION="1.2"

CONFIG_FILE="/root/Proxmox-Updater/update.conf"

# Colors
BL="\e[36m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Usage
function USAGE {
  echo -e "\nUsage: $0 {COMMAND}\n"
  echo -e "{COMMAND}:"
  echo -e "========="
  echo -e "  host                 Host-Mode"
  echo -e "  cluster              Cluster-Mode\n"
  echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
}

function READ_WRITE_CONFIG {
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' $CONFIG_FILE)
}

## HOST ##
# Host Check Start
function HOST_CHECK_START {
  for HOST in $HOSTS; do
    CHECK_HOST "$HOST"
  done
}

# Host Check
function CHECK_HOST {
  HOST=$1
  ssh "$HOST" mkdir -p /root/Proxmox-Updater
  scp /root/Proxmox-Updater/update.conf "$HOST":/root/Proxmox-Updater/update.conf >/dev/null 2>&1
  ssh "$HOST" 'bash -s' < "$0" -- "-c host" #>/dev/null 2>&1
}

function CHECK_HOST_ITSELF {
  apt-get update >/dev/null 2>&1
  SECURITY_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst.*security" | tr -d '\n')
  NORMAL_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst." | tr -d '\n')
  if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "${GN}Host${CL} : ${GN}$HOSTNAME${CL}"
  fi
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
function CONTAINER_CHECK_START {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    if [[ $ONLY == "" ]] && [[ $EXCLUDED =~ $CONTAINER ]]; then
      continue
    elif [[ $ONLY != "" ]] && ! [[ $ONLY =~ $CONTAINER ]]; then
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ $STATUS == "status: stopped" && $STOPPED == true ]]; then
        # Start the container
        pct start "$CONTAINER"
        sleep 5
        CHECK_CONTAINER "$CONTAINER"
        # Stop the container
        pct shutdown "$CONTAINER" &
      elif [[ $STATUS == "status: running" && $RUNNING == true ]]; then
        CHECK_CONTAINER "$CONTAINER"
      fi
    fi
  done
  rm -rf temp
}

# Container Check
function CHECK_CONTAINER {
  CONTAINER=$1
  pct config "$CONTAINER" > temp
  OS=$(awk '/^ostype/' temp | cut -d' ' -f2)
  if [[ $OS =~ centos ]]; then
    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
  else
    NAME=$(pct exec "$CONTAINER" hostname)
  fi
  if [[ $OS =~ ubuntu ]] || [[ $OS =~ debian ]] || [[ $OS =~ devuan ]]; then
    pct exec "$CONTAINER" -- bash -c "apt-get update" >/dev/null 2>&1
    SECURITY_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'")
    NORMAL_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'")
    if [[ $SECURITY_APT_UPDATES -gt 0 || $NORMAL_APT_UPDATES != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
    fi
    if [[ $SECURITY_APT_UPDATES -gt 0 && $NORMAL_APT_UPDATES != 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
    elif [[ $SECURITY_APT_UPDATES -gt 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / "
    elif [[ $NORMAL_APT_UPDATES -gt 0 ]]; then
      echo -e "N: $NORMAL_APT_UPDATES"
    fi
  elif [[ $OS =~ fedora ]]; then
    pct exec "$CONTAINER" -- bash -c "dnf -y update" >/dev/null 2>&1
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "dnf check-update| grep -Ec ' updates$'")
    if [[ $UPDATES -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ $OS =~ archlinux ]]; then
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "pacman -Qu | wc -l")
    if [[ $UPDATES -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ $OS =~ alpine ]]; then
    return
  else
    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "yum -q check-update | wc -l")
    if [[ $UPDATES -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  fi
}

## VM ##
# VM Check Start
function VM_CHECK_START {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through the VMs
  for VM in $VMS; do
    PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
    if [[ $ONLY == "" && $EXCLUDED =~ $VM ]]; then
      continue
    elif [[ $ONLY != "" ]] && ! [[ $ONLY =~ $VM ]]; then
      continue
    elif [[ $PRE_OS =~ w ]]; then
      continue
    else
      STATUS=$(qm status "$VM")
      if [[ $STATUS == "status: stopped" && $STOPPED == true ]]; then
        # Start the VM
        qm set "$VM" --agent 1 >/dev/null 2>&1
        qm start "$VM" >/dev/null 2>&1
        sleep 30
        CHECK_VM "$VM"
        # Stop the VM
        qm shutdown "$VM"
      elif [[ $STATUS == "status: running" && $RUNNING == true ]]; then
        CHECK_VM "$VM"
      fi
    fi
  done
}

# VM Check
function CHECK_VM {
  VM=$1
  if qm guest exec "$VM" test >/dev/null 2>&1; then
#  REBOOT_REQUIRED=$(qm guest cmd "$VM" -- bash -c "-f "/var/run/reboot-required.pkgs"")
    NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
    OS=$(qm guest cmd "$VM" get-osinfo | grep name)
    if [[ $OS =~ Ubuntu ]] || [[ $OS =~ Debian ]] || [[ $OS =~ Devuan ]]; then
      qm guest exec "$VM" -- bash -c "apt-get update" >/dev/null 2>&1
      SECURITY_APT_UPDATES=$(qm guest exec "$VM" -- bash -c "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      NORMAL_APT_UPDATES=$(qm guest exec "$VM" -- bash -c "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ $SECURITY_APT_UPDATES -gt 0 || $NORMAL_APT_UPDATES -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
      fi
      if [[ $SECURITY_APT_UPDATES -gt 0 && $NORMAL_APT_UPDATES -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
      elif [[ $SECURITY_APT_UPDATES -gt 0 ]]; then
        echo -e "S: $SECURITY_APT_UPDATES / "
      elif [[ $NORMAL_APT_UPDATES -gt 0 ]]; then
        echo -e "N: $NORMAL_APT_UPDATES"
      fi
    elif [[ $OS =~ Fedora ]]; then
      qm guest exec "$VM" -- bash -c "dnf -y update" >/dev/null 2>&1
      UPDATES=$(qm guest exec "$VM" -- bash -c "dnf check-update| grep -Ec ' updates$'" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ $UPDATES -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ $OS =~ Arch ]]; then
      UPDATES=$(qm guest exec "$VM" -- bash -c "pacman -Qu | wc -l" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ $UPDATES -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    elif [[ $OS =~ Alpine ]]; then
      return
    elif [[ $OS =~ CentOS ]]; then
      UPDATES=$(qm guest exec "$VM" -- bash -c "yum -q check-update | wc -l" | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
      if [[ $UPDATES -gt 0 ]]; then
        echo -e "${GN}VM ${BL}$VM${CL} : ${GN}$NAME${CL}"
        echo -e "$UPDATES"
      fi
    fi
  fi
}

# Output to file
#if [[ $RICM != true ]]; then
  touch /root/Proxmox-Updater/check-output
  exec > >(tee /root/Proxmox-Updater/check-output)
#fi

# Check Cluster Mode
if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster"
else
  MODE="Host"
fi

# Run
READ_WRITE_CONFIG
parse_cli()
{
  while test $# -gt -0
  do
    argument="$1"
    case "$argument" in
      -c)
        RICM=true
        ;;
      host)
        COMMAND=true
        if [[ $WITH_HOST == true ]]; then CHECK_HOST_ITSELF; fi
        if [[ $WITH_LXC == true ]]; then CONTAINER_CHECK_START; fi
        if [[ $WITH_VM == true ]]; then VM_CHECK_START; fi
        ;;
      cluster)
        COMMAND=true
        HOST_CHECK_START
        ;;
      *)
        echo -e "\n${RD}  Error: Got an unexpected argument \"$argument\"${CL}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}
parse_cli "$@"

# Run without commands (Automatic Mode)
if [[ $COMMAND != true ]]; then
  if [[ $MODE =~ Cluster ]]; then HOST_CHECK_START; else
    if [[ $WITH_HOST == true ]]; then CHECK_HOST_ITSELF; fi
    if [[ $WITH_LXC == true ]]; then CONTAINER_CHECK_START; fi
    if [[ $WITH_VM == true ]]; then VM_CHECK_START; fi
  fi
fi

exit 0
