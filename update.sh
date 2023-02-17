#!/bin/bash
# https://github.com/BassT23/Proxmox

# Variable / Function
LOG_FILE=/var/log/update-$HOSTNAME.log    # <- change location for logfile if you want
VERSION="3.4.2"

# Also Update VM? (under development)
WITH_VM=true

#live
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/master"
#development
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/development"

# Colors
BL='\033[36m'
RD='\033[01;31m'
GN='\033[1;92m'
CL='\033[m'

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
#  VERSION_CHECK
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
      echo -e "  -h --help            Show this help"
      echo -e "  -v --version         Show Proxmox-Updater Version"
      echo -e "  -s --silent          Silent / Headless Mode\n"
      echo -e "  -up                  Update Proxmox-Updater\n"
      echo -e "Commands:"
      echo -e "========="
      echo -e "  host                 Host-Mode"
      echo -e "  cluster              Cluster-Mode"
      echo -e "  uninstall            Uninstall Proxmox-Updater\n"
      echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check in Header
function VERSION_CHECK {
  curl -s $SERVER_URL/update.sh > /root/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update.sh)
  if [[ $VERSION != "$SERVER_VERSION" ]]; then
    echo -e "\n${RD}   *** A newer version is available ***${CL}\n \
      Installed: $VERSION / Server: $SERVER_VERSION\n"
    if [[ $HEADLESS != true ]]; then
      echo -e "${RD}Want to update first Proxmox-Updater?${CL}"
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
  rm -rf /root/update.sh
}

#Update Proxmox-Updater
function UPDATE {
  bash <(curl -s $SERVER_URL/install.sh) update
  exit 2
}

# Uninstall
function UNINSTALL {
  echo -e "\n${BL}[Info]${GN} Uninstall Proxmox-Updater${CL}\n"
  echo -e "${RD}Really want to remove Proxmox-Updater?${CL}"
  read -p "Type [Y/y] for yes - enything else will exit " -n 1 -r -s
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    bash <(curl -s $SERVER_URL/install.sh) uninstall
  else
    exit 2
  fi
}

# LXC Extras
function LXC_EXTRAS {
  if [[ $HEADLESS != true ]]; then
    echo -e "\n--- Searching for extra updates ---\n"
    pct push "$CONTAINER" -- /root/Proxmox-Update-Scripts/update-extras.sh /root/update-extras.sh
    pct exec "$CONTAINER" -- bash -c "chmod +x /root/update-extras.sh && \
                                      /root/update-extras.sh && \
                                      rm -rf /root/update-extras.sh"
  else
    echo -e "--- Skip Extra Updates because of Headless Mode---\n"
  fi
}

# Host Update
function UPDATE_HOST {
  HOST=$1
  echo -e "\n${BL}[Info]${GN} Updating${CL} : ${GN}$HOST${CL}"
  ssh "$HOST" mkdir -p /root/Proxmox-Update-Scripts/
  scp /root/Proxmox-Update-Scripts/update-extras.sh "$HOST":/root/Proxmox-Update-Scripts/update-extras.sh
  if [[ $HEADLESS == true ]]; then
    ssh "$HOST" 'bash -s' < "$0" -- "-s -c host"
  else
    ssh "$HOST" 'bash -s' < "$0" -- "-c host"
  fi
}

# Host Update Start
function HOST_UPDATE_START {
  for HOST in $HOSTS; do
    UPDATE_HOST "$HOST"
  done
}

# Container Update
function UPDATE_CONTAINER {
  CONTAINER=$1
  NAME=$(pct exec "$CONTAINER" hostname)
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  pct config "$CONTAINER" > temp
  OS=$(awk '/^ostype/' temp | cut -d' ' -f2)
  if [[ $OS =~ ubuntu ]] || [[ $OS =~ debian ]] || [[ $OS =~ devuan ]]; then
    echo -e "--- APT UPDATE ---"
    pct exec "$CONTAINER" -- bash -c "apt-get update"
    if [[ $HEADLESS == true ]]; then
      echo -e "\n--- APT UPGRADE HEADLESS ---"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    else
      echo -e "\n--- APT UPGRADE ---"
      pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    fi
      echo -e "\n--- APT CLEANING ---"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y"
      LXC_EXTRAS
  elif [[ $OS =~ fedora ]]; then
      echo -e "--- DNF UPDATE ---"
      pct exec "$CONTAINER" -- bash -c "dnf -y update"
      echo -e "\n--- DNF UPGRATE ---"
      pct exec "$CONTAINER" -- bash -c "dnf -y upgrade"
      echo -e "\n--- DNF CLEANING ---"
      pct exec "$CONTAINER" -- bash -c "dnf -y --purge autoremove"
      LXC_EXTRAS
  elif [[ $OS =~ archlinux ]]; then
      echo -e "--- PACMAN UPDATE ---"
      pct exec "$CONTAINER" -- bash -c "pacman -Syyu --noconfirm"
      LXC_EXTRAS
  elif [[ $OS =~ alpine ]]; then
      echo -e "--- APK UPDATE ---"
      pct exec "$CONTAINER" -- ash -c "apk -U upgrade"
      LXC_EXTRAS
  else
      echo -e "--- YUM UPDATE ---"
      pct exec "$CONTAINER" -- bash -c "yum -y update"
      LXC_EXTRAS
  fi
}

# Container Update Start
function CONTAINER_UPDATE_START {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    status=$(pct status "$CONTAINER")
    if [[ $status == "status: stopped" ]]; then
      echo -e "${BL}[Info]${GN} Starting${BL} $CONTAINER ${CL}\n"
      # Start the container
      pct start "$CONTAINER"
      echo -e "${BL}[Info]${GN} Waiting for${BL} $CONTAINER${CL}${GN} to start ${CL}\n"
      sleep 5
      UPDATE_CONTAINER "$CONTAINER"
      echo -e "${BL}[Info]${GN} Shutting down${BL} $CONTAINER ${CL}\n"
      # Stop the container
      pct shutdown "$CONTAINER" &
    elif [[ $status == "status: running" ]]; then
      UPDATE_CONTAINER "$CONTAINER"
    fi
  done
  rm -rf temp
}

# VM Update
function UPDATE_VM {
  VM=$1
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    VM_NAME=$(qm guest cmd "$VM" get-host-name | grep host-name | cut -c 18-)
    echo -e "\n${BL}[Info]${GN} Updating VM ${BL}$VM${CL} : ${GN}$VM_NAME${CL}\n"
    OS=$(qm guest cmd "$VM" get-osinfo | grep name)
      if [[ $OS =~ Ubuntu ]] || [[ $OS =~ Debian ]] || [[ $OS =~ Devuan ]]; then
        echo -e "--- APT UPDATE ---"
        qm guest exec "$VM" -- bash -c "apt-get update" | tail -n +4 | head -n -1
        echo -e "\n--- APT UPGRADE ---"
        qm guest exec "$VM" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +4 | head -n -1
        echo -e "\n--- APT CLEANING ---"
        qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1
      elif [[ $OS =~ Fedora ]]; then
        echo -e "--- DNF UPDATE ---"
        qm guest exec "$CONTAINER" -- bash -c "dnf -y update && echo" | tail -n +4 | head -n -1
        echo -e "--- DNF UPGRATE ---"
        qm guest exec "$CONTAINER" -- bash -c "dnf -y upgrade && echo" | tail -n +4 | head -n -1
        echo -e "--- DNF CLEANING ---"
        qm guest exec "$CONTAINER" -- bash -c "dnf -y --purge autoremove && echo" | tail -n +4 | head -n -1
      elif [[ $OS =~ Arch ]]; then
        echo -e "--- PACMAN UPDATE ---"
        qm guest exec "$CONTAINER" -- bash -c "pacman -Syyu --noconfirm" | tail -n +4 | head -n -1
      elif [[ $OS =~ Alpine ]]; then
        echo -e "--- APK UPDATE ---"
        qm guest exec "$CONTAINER" -- ash -c "apk -U upgrade" | tail -n +4 | head -n -1
      elif [[ $OS =~ CentOS ]]; then
        echo -e "--- YUM UPDATE ---"
        qm guest exec "$CONTAINER" -- bash -c "yum -y update" | tail -n +4 | head -n -1
      else
        echo -e "${RD}  System is not supported \n  Maybe with later version ;)${CL}"
      fi
  else
    echo -e "\n${RD}  QEMU guest agent is not installed or running on VM ${CL}\n\
  You must install and start it by yourself!\n\
  Please check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
  fi
}

# VM Update Start
function VM_UPDATE_START {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c 8-10)
  # Loop through the VMs
  for VM in $VMS; do
    status=$(qm status "$VM")
#    qm set "$VM" --agent 1 > /dev/null 2>&1   # must be set by user with additional restart!
    if [[ $status == "status: stopped" ]]; then
      echo -e "${BL}[Info]${GN} Starting${BL} $VM ${CL}\n"
      # Start the VM
      qm start "$VM"
      echo -e "${BL}[Info]${GN} Waiting for${BL} $VM${CL}${GN} to start ${CL}\n"
      sleep 5
      UPDATE_VM "$VM"
      echo -e "${BL}[Info]${GN} Shutting down${BL} $VM ${CL}\n"
      # Stop the VM
      qm shutdown "$VM" &
    elif [[ $status == "status: running" ]]; then
      UPDATE_VM "$VM"
    fi
#    qm set "$VM" --agent 0 > /dev/null 2>&1
  done
}

function UPDATE_HOST_ITSELF {
  echo -e "\n--- APT UPDATE ---" && apt-get update
  if [[ $HEADLESS == true ]]; then
    echo -e "\n--- APT UPGRADE HEADLESS ---" && \
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  else
    echo -e "\n--- APT UPGRADE ---" && \
            apt-get upgrade -y
  fi
  echo -e "\n--- APT CLEANING ---" && \
          apt-get --purge autoremove -y && echo
}

# Logging
if [[ $RICM != true ]]; then
  touch "$LOG_FILE"
  exec &> >(tee "$LOG_FILE")
fi
function CLEAN_LOGFILE {
  if [[ $RICM != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
    cat $LOG_FILE | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE"
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
      echo -e "${GN}Finished, All Containers Updated.${CL}\n"
      /root/Proxmox-Update-Scripts/exit/passed.sh
      CLEAN_LOGFILE
    fi
  # Update Error
  else
    if [[ $RICM != true ]]; then
      echo -e "${RD}Error during Update --- Exit Code: $EXIT_CODE${CL}\n"
      /root/Proxmox-Update-Scripts/exit/error.sh
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
parse_cli()
{
  while test $# -gt -0
  do
    _key="$1"
    case "$_key" in
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
          echo -e "\n${BL}[Info]${GN} Updating${CL} : ${GN}$HOSTNAME${CL}"
        fi
#        UPDATE_HOST_ITSELF
#        CONTAINER_UPDATE_START
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
        echo -e "${RD}Error: Got an unexpected argument \"$_key\"${CL}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}
parse_cli "$@"

# Run without commands (Automatic Mode)
if [[ $COMMAND != true && $RICM != true ]]; then
  if [[ -f /etc/corosync/corosync.conf ]]; then
    MODE=" Cluster"
    HEADER_INFO
    HOST_UPDATE_START
  else
    MODE="  Host  "
    HEADER_INFO
    echo -e "\n${BL}[Info]${GN} Updating${CL} : ${GN}$HOSTNAME${CL}"
    UPDATE_HOST_ITSELF
    CONTAINER_UPDATE_START
    if [[ $WITH_VM == true ]]; then VM_UPDATE_START; fi
  fi
fi

exit 0
