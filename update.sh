#!/bin/bash
# https://github.com/BassT23/Proxmox

# Variable / Function
LOG_FILE=/var/log/update-$HOSTNAME.log    # <- change location for logfile if you want
VERSION="3.6.1"

#live
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/master"
#beta
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/beta"
#development
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/development"

CONFIG_FILE="/root/Proxmox-Updater/update.conf"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Header
function HEADER_INFO {
  clear
  echo -e "\n \
    https://github.com/BassT23/Proxmox"
  cat <<'EOF'
     ____
    / __ \_________  _  ______ ___  ____  _  __
   / /_/ / ___/ __ \| |/_/ __ `__ \/ __ \| |/_/
  / ____/ /  / /_/ />  </ / / / / / /_/ />  <
 /_/   /_/   \____/_/|_/_/ /_/ /_/\____/_/|_|
      __  __          __      __
     / / / /___  ____/ /___ _/ /____  ____
    / / / / __ \/ __  / __ `/ __/ _ \/ __/
   / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
   \____/ .___/\____/\____/\__/\___/_/
       /_/
EOF
  echo -e "\n \
           *** Mode: $MODE ***"
  if [[ $HEADLESS == true ]]; then
    echo -e "            ***    Headless    ***"
  else
    echo -e "            ***  Interactive   ***"
  fi
  CHECK_ROOT
  if [[ $CHECK_VERSION == true ]]; then VERSION_CHECK; else echo; fi
}

# Check root
function CHECK_ROOT {
  if [[ $RICM != true && $EUID -ne 0 ]]; then
      echo -e "\n ${RD}--- Please run this as root ---${CL}\n"
      exit 2
  fi
}

# Usage
function USAGE {
  if [[ $HEADLESS != true ]]; then
      echo -e "\nUsage: $0 [OPTIONS...] {COMMAND}\n"
      echo -e "[OPTIONS] Manages the Proxmox-Updater:"
      echo -e "======================================"
      echo -e "  -s --silent          Silent / Headless Mode\n"
      echo -e "{COMMAND}:"
      echo -e "========="
      echo -e "  -h --help            Show this help"
      echo -e "  -v --version         Show Proxmox-Updater Version"
      echo -e "  -up                  Update Proxmox-Updater"
      echo -e "  uninstall            Uninstall Proxmox-Updater\n"
      echo -e "  host                 Host-Mode"
      echo -e "  cluster              Cluster-Mode\n"
      echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check in Header
function VERSION_CHECK {
  curl -s $SERVER_URL/update.sh > /root/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update.sh)
  if [[ $VERSION != "$SERVER_VERSION" ]]; then
    echo -e "\n${OR}   *** A newer version is available ***${CL}\n \
      Installed: $VERSION / Server: $SERVER_VERSION\n"
    if [[ $HEADLESS != true ]]; then
      echo -e "${OR}Want to update Proxmox-Updater first?${CL}"
      read -p "Type [Y/y] or Enter for yes - enything else will skip " -n 1 -r -s
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh) update
      fi
      echo
    fi
  else
    echo -e "\n             ${GN}Script is UpToDate${CL}\n \
               Version: $VERSION"
  fi
  rm -rf /root/update.sh && echo
}

#Update Proxmox-Updater
function UPDATE {
  bash <(curl -s $SERVER_URL/install.sh) update
  exit 2
}

# Uninstall
function UNINSTALL {
  echo -e "\n${BL}[Info]${OR} Uninstall Proxmox-Updater${CL}\n"
  echo -e "${RD}Really want to remove Proxmox-Updater?${CL}"
  read -p "Type [Y/y] for yes - enything else will exit " -n 1 -r -s
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    bash <(curl -s $SERVER_URL/install.sh) uninstall
  else
    exit 2
  fi
}

function READ_WRITE_CONFIG {
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' $CONFIG_FILE)
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^Only=/ {print $2}' $CONFIG_FILE)
}

# Extras
function EXTRAS {
  if [[ $HEADLESS != true || $EXTRA_IN_HEADLESS != false ]]; then
    echo -e "\n${OR}--- Searching for extra updates ---${CL}"
    pct exec "$CONTAINER" -- bash -c "mkdir -p /root/Proxmox-Updater/"
    pct push "$CONTAINER" -- /root/Proxmox-Updater/update-extras.sh /root/Proxmox-Updater/update-extras.sh
    pct push "$CONTAINER" -- /root/Proxmox-Updater/update.conf /root/Proxmox-Updater/update.conf
    pct exec "$CONTAINER" -- bash -c "chmod +x /root/Proxmox-Updater/update-extras.sh && \
                                      /root/Proxmox-Updater/update-extras.sh && \
                                      rm -rf /root/Proxmox-Updater"
    echo -e "${GN}---   Finished extra updates    ---${CL}\n"
    if [[ $WILL_STOP != true ]]; then echo; fi
  else
    echo -e "${OR}--- Skip Extra Updates because of Headless Mode or user settings ---${CL}\n\n"
  fi
}

## HOST ##
# Host Update Start
function HOST_UPDATE_START {
  for HOST in $HOSTS; do
    UPDATE_HOST "$HOST"
  done
}

# Host Update
function UPDATE_HOST {
  HOST=$1
  echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$HOST${CL}\n"
  ssh "$HOST" mkdir -p /root/Proxmox-Updater
  scp /root/Proxmox-Updater/update-extras.sh "$HOST":/root/Proxmox-Updater/update-extras.sh
  scp /root/Proxmox-Updater/update.conf "$HOST":/root/Proxmox-Updater/update.conf
  if [[ $HEADLESS == true ]]; then
    ssh "$HOST" 'bash -s' < "$0" -- "-s -c host"
  else
    ssh "$HOST" 'bash -s' < "$0" -- "-c host"
  fi
}

function UPDATE_HOST_ITSELF {
  echo -e "${OR}--- APT UPDATE ---${CL}" && apt-get update
  if [[ $HEADLESS == true ]]; then
    echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}" && \
            DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
  else
    echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
            apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
  fi
  echo -e "\n${OR}--- APT CLEANING ---${CL}" && \
          apt-get --purge autoremove -y && echo && echo
}

## Container ##
# Container Update Start
function CONTAINER_UPDATE_START {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    if [[ $EXCLUDED =~ $CONTAINER ]]; then
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by user${CL}\n\n"
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ $STATUS == "status: stopped" && $STOPPED == true ]]; then
        # Start the container
        WILL_STOP="true"
        echo -e "${BL}[Info]${GN} Starting LXC${BL} $CONTAINER ${CL}"
        pct start "$CONTAINER"
        echo -e "${BL}[Info]${GN} Waiting for LXC${BL} $CONTAINER${CL}${GN} to start ${CL}"
        sleep 5
        UPDATE_CONTAINER "$CONTAINER"
        # Stop the container
        echo -e "${BL}[Info]${GN} Shutting down LXC${BL} $CONTAINER ${CL}\n\n"
        pct shutdown "$CONTAINER" &
        WILL_STOP="false"
      elif [[ $STATUS == "status: running" && $RUNNING == true ]]; then
        UPDATE_CONTAINER "$CONTAINER"
      fi
    fi
  done
  rm -rf temp
}

# Container Update
function UPDATE_CONTAINER {
  CONTAINER=$1
  NAME=$(pct exec "$CONTAINER" hostname)
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  pct config "$CONTAINER" > temp
  OS=$(awk '/^ostype/' temp | cut -d' ' -f2)
  if [[ $OS =~ ubuntu ]] || [[ $OS =~ debian ]] || [[ $OS =~ devuan ]]; then
    echo -e "${OR}--- APT UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "apt-get update"
    if [[ $HEADLESS == true ]]; then
      echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y"
      EXTRAS
  elif [[ $OS =~ fedora ]]; then
      echo -e "${OR}--- DNF UPDATE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "dnf -y update"
      echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "dnf -y upgrade"
      echo -e "\n${OR}--- DNF CLEANING ---${CL}"
      pct exec "$CONTAINER" -- bash -c "dnf -y --purge autoremove"
      EXTRAS
  elif [[ $OS =~ archlinux ]]; then
      echo -e "${OR}--- PACMAN UPDATE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "pacman -Syyu --noconfirm"
      EXTRAS
  elif [[ $OS =~ alpine ]]; then
      echo -e "${OR}--- APK UPDATE ---${CL}"
      pct exec "$CONTAINER" -- ash -c "apk -U upgrade"
      EXTRAS
  else
      echo -e "\n${OR}--- YUM UPDATE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "yum -y update"
      EXTRAS
  fi
}

## VM ##
# VM Update Start
function VM_UPDATE_START {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through the VMs
  for VM in $VMS; do
    PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
    if [[ $EXCLUDED =~ $VM ]]; then
      echo -e "${BL}[Info] Skipped VM $VM by user${CL}\n\n"
    elif [[ $PRE_OS =~ w ]]; then
      echo -e "${RD}  Windows is not supported for now.\n  Maybe with later version ;)${CL}\n\n"
    else
      STATUS=$(qm status "$VM")
      if [[ $STATUS == "status: stopped" && $STOPPED == true ]]; then
        # Start the VM
        WILL_STOP="true"
        echo -e "${BL}[Info]${GN} Starting VM${BL} $VM ${CL}"
        qm set "$VM" --agent 1 >/dev/null 2>&1
        qm start "$VM" >/dev/null 2>&1
        echo -e "${BL}[Info]${GN} Waiting for VM${BL} $VM${CL}${GN} to start${CL}"
        echo -e "${OR}This will take some time, ... 30 secounds is set!${CL}"
        sleep 30
        UPDATE_VM "$VM"
        # Stop the VM
        echo -e "${BL}[Info]${GN} Shutting down VM${BL} $VM ${CL}\n\n"
        qm shutdown "$VM" &
        WILL_STOP="false"
      elif [[ $STATUS == "status: running" && $RUNNING == true ]]; then
        UPDATE_VM "$VM"
      fi
    fi
  done
}

# VM Update
function UPDATE_VM {
  VM=$1
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    VM_NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
    echo -e "${BL}[Info]${GN} Updating VM ${BL}$VM${CL} : ${GN}$VM_NAME${CL}\n"
    OS=$(qm guest cmd "$VM" get-osinfo | grep name)
      if [[ $OS =~ Ubuntu ]] || [[ $OS =~ Debian ]] || [[ $OS =~ Devuan ]]; then
        echo -e "${OR}--- APT UPDATE ---${CL}"
        qm guest exec "$VM" -- bash -c "apt-get update" | tail -n +4 | head -n -1 | cut -c 17-
        echo -e "\n${OR}--- APT UPGRADE ---${CL}"
        qm guest exec "$VM" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +2 | head -n -1
        echo -e "\n${OR}--- APT CLEANING ---${CL}"
        qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1 | cut -c 17-
      elif [[ $OS =~ Fedora ]]; then
        echo -e "${OR}--- DNF UPDATE ---${CL}"
        qm guest exec "$VM" -- bash -c "dnf -y update && echo" | tail -n +4 | head -n -1 | cut -c 17-
        echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
        qm guest exec "$VM" -- bash -c "dnf -y upgrade && echo" | tail -n +2 | head -n -1
        echo -e "\n${OR}--- DNF CLEANING ---${CL}"
        qm guest exec "$VM" -- bash -c "dnf -y --purge autoremove && echo" | tail -n +4 | head -n -1 | cut -c 17-
      elif [[ $OS =~ Arch ]]; then
        echo -e "${OR}--- PACMAN UPDATE ---${CL}"
        qm guest exec "$VM" -- bash -c "pacman -Syyu --noconfirm" | tail -n +2 | head -n -1
      elif [[ $OS =~ Alpine ]]; then
        echo -e "${OR}--- APK UPDATE ---${CL}"
        qm guest exec "$VM" -- ash -c "apk -U upgrade" | tail -n +2 | head -n -1
      elif [[ $OS =~ CentOS ]]; then
        echo -e "${OR}--- YUM UPDATE ---${CL}"
        qm guest exec "$VM" -- bash -c "yum -y update" | tail -n +2 | head -n -1
      else
        echo -e "${RD}  System is not supported.\n  Maybe with later version ;)\n${CL}"
        echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
      fi
      echo
      if [[ $WILL_STOP != true ]]; then echo; fi
  else
    echo -e "${BL}[Info]${GN} Updating VM ${BL}$VM${CL}\n"
    echo -e "${RD}  QEMU guest agent is not installed or running on VM ${CL}\n\
  ${OR}You must install and start it by yourself!${CL}\n\
  Please check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n\n"
  fi
}

# Logging
if [[ $RICM != true ]]; then
  touch "$LOG_FILE"
  exec &> >(tee "$LOG_FILE")
fi

function CLEAN_LOGFILE {
  if [[ $RICM != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
    cat $LOG_FILE | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE" >/dev/null 2>&1
    chmod 640 "$LOG_FILE"
    if [[ -f ./tmp.log ]]; then
      rm -rf ./tmp.log
    fi
  fi
}

function EXIT {
  EXIT_CODE=$?
  # Exit direct
  if [[ $EXIT_CODE == 2 ]]; then
    exit
  # Update Finish
  elif [[ $EXIT_CODE == 0 ]]; then
    if [[ $RICM != true ]]; then
      echo -e "${GN}Finished, All Updates Done.${CL}\n"
      /root/Proxmox-Updater/exit/passed.sh
      CLEAN_LOGFILE
    fi
  # Update Error
  else
    if [[ $RICM != true ]]; then
      echo -e "${RD}Error during Update --- Exit Code: $EXIT_CODE${CL}\n"
      /root/Proxmox-Updater/exit/error.sh
      CLEAN_LOGFILE
    fi
  fi

}

# Exit Code
set -e
trap EXIT EXIT

# Check Cluster Mode
if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
fi

# Update Start
export TERM=xterm-256color
READ_WRITE_CONFIG
parse_cli()
{
  while test $# -gt -0
  do
    argument="$1"
    case "$argument" in
      -h|--help)
        USAGE
        exit 2
        ;;
      -s|--silent)
        HEADLESS=true
        ;;
      -v|--version)
        VERSION_CHECK
        exit 2
        ;;
      -c)
        RICM=true
        ;;
      host)
        COMMAND=true
        if [[ $RICM != true ]]; then
          MODE="  Host  "
          HEADER_INFO
          echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$HOSTNAME${CL}\n"
        fi
        if [[ $WITH_HOST == true ]]; then UPDATE_HOST_ITSELF; fi
        if [[ $WITH_LXC == true ]]; then CONTAINER_UPDATE_START; fi
        if [[ $WITH_VM == true ]]; then VM_UPDATE_START; fi
        ;;
      cluster)
        COMMAND=true
        MODE=" Cluster"
        HEADER_INFO
        HOST_UPDATE_START
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        exit 0
        ;;
      -up)
        COMMAND=true
        UPDATE
        exit 0
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
if [[ -f /etc/corosync/corosync.conf ]]; then MODE=" Cluster"; else MODE="  Host  "; fi
if [[ $COMMAND != true ]]; then
  HEADER_INFO
  if [[ $MODE =~ Cluster ]]; then HOST_UPDATE_START; else
    echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$HOSTNAME${CL}"
    if [[ $WITH_HOST == true ]]; then UPDATE_HOST_ITSELF; fi
    if [[ $WITH_LXC == true ]]; then CONTAINER_UPDATE_START; fi
    if [[ $WITH_VM == true ]]; then VM_UPDATE_START; fi
  fi
fi

exit 0
