#!/bin/bash

# Check Updates

VERSION="1.0"

#if [ -f "/var/run/reboot-required.pkgs" ]; then
#  echo "reboot required"
#fi

CONFIG_FILE="/root/Proxmox-Updater/update.conf"

# Colors
BL="\e[36m"
OR="\e[1;33m"
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
#  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' $CONFIG_FILE)
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' $CONFIG_FILE)
}

function CONFIG_NOTIFICATION {
  if [[ $ONLY == "" && $EXCLUDED != "" ]]; then
    echo -e "${OR}Exclud is set. Not all machines were checked.${CL}"
  elif [[ $ONLY != "" ]]; then
    echo -e "${OR}Only is set. Not all machines were checked.${CL}"
  fi
}

## HOST ##
# Host Update Start
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
  ssh "$HOST" 'bash -s' < "$0" -- "-c host" >/dev/null 2>&1
}

function CHECK_HOST_ITSELF {
  SECURITY_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst.*security" | tr -d '\n')
  NORMAL_APT_UPDATES=$(apt-get -s upgrade | grep -ci "^inst." | tr -d '\n')
  if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "${GN}Host${CL} : ${GN}$HOST${CL}"
  fi
  if [[ $SECURITY_APT_UPDATES != 0 && $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
  elif [[ $SECURITY_APT_UPDATES != 0 ]]; then
    echo -e "S: $SECURITY_APT_UPDATES / "
  elif [[ $NORMAL_APT_UPDATES != 0 ]]; then
    echo -e "N: $NORMAL_APT_UPDATES"
  fi
#  REBOOT_REQUIRED=$(pct exec $CONTAINER -- bash -c "-f "/var/run/reboot-required.pkgs"")
}

## Container ##
# Container Update Start
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

# Container Update
function CHECK_CONTAINER {
  CONTAINER=$1
  NAME=$(pct exec "$CONTAINER" hostname)
  pct config "$CONTAINER" > temp
  OS=$(awk '/^ostype/' temp | cut -d' ' -f2)
  if [[ $OS =~ ubuntu ]] || [[ $OS =~ debian ]] || [[ $OS =~ devuan ]]; then
    SECURITY_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'")
    NORMAL_APT_UPDATES=$(pct exec "$CONTAINER" -- bash -c "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'")
    if [[ $SECURITY_APT_UPDATES != 0 || $NORMAL_APT_UPDATES != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
    fi
    if [[ $SECURITY_APT_UPDATES != 0 && $NORMAL_APT_UPDATES != 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / N: $NORMAL_APT_UPDATES"
    elif [[ $SECURITY_APT_UPDATES != 0 ]]; then
      echo -e "S: $SECURITY_APT_UPDATES / "
    elif [[ $NORMAL_APT_UPDATES != 0 ]]; then
      echo -e "N: $NORMAL_APT_UPDATES"
    fi
  elif [[ $OS =~ fedora ]]; then
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "dnf check-update| grep -Ec ' updates$'")
    if [[ $UPDATES != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ $OS =~ archlinux ]]; then
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "pacman -Qu | wc -l")
    if [[ $UPDATES != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  elif [[ $OS =~ alpine ]]; then
    echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
    echo "not supported for now - can't find command for numeric update output :("
#    UPDATES=$(pct exec "$CONTAINER" -- ash -c "apk -U upgrade")
#    if [[ $UPDATES != 0 ]]; then
#      echo -e "NU: $UPDATES"
#    fi
  else
    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
    UPDATES=$(pct exec "$CONTAINER" -- bash -c "yum -q check-update | wc -l")
    if [[ $UPDATES != 0 ]]; then
      echo -e "${GN}LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}"
      echo -e "$UPDATES"
    fi
  fi
}

# Output to file
if [[ $RICM != true ]]; then
  touch /root/Proxmox-Updater/check-output
  exec > >(tee /root/Proxmox-Updater/check-output)
fi

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
        if [[ $RICM != true ]]; then
          CONFIG_NOTIFICATION
          echo -e "Security Updates = S / Normal Updates = N"
        fi
        if [[ $WITH_HOST == true ]]; then CHECK_HOST_ITSELF; fi
        if [[ $WITH_LXC == true ]]; then CONTAINER_CHECK_START; fi
#        if [[ $WITH_VM == true ]]; then VM_CHECK_START; fi
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
  CONFIG_NOTIFICATION
  echo -e "Security Updates = S / Normal Updates = N"
  if [[ $MODE == Cluster ]]; then HOST_CHECK_START; else
    if [[ $WITH_HOST == true ]]; then CHECK_HOST_ITSELF; fi
    if [[ $WITH_LXC == true ]]; then CONTAINER_CHECK_START; fi
#    if [[ $WITH_VM == true ]]; then VM_CHECK_START; fi
  fi
fi

exit 0
