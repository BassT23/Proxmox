#!/bin/bash

##########
# Update #
##########

VERSION="3.8.1"

# Branch
BRANCH="development"

# Variable / Function
LOG_FILE=/var/log/update-"$HOSTNAME".log    # <- change location for logfile if you want
CONFIG_FILE="/root/Proxmox-Updater/update.conf"
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Header
HEADER_INFO () {
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
  if [[ "$INFO" != false ]]; then
    echo -e "\n \
           ***  Mode: $MODE***"
    if [[ "$HEADLESS" == true ]]; then
      echo -e "            ***    Headless    ***"
    else
      echo -e "            ***   Interactive  ***"
    fi
  fi
  CHECK_ROOT
  if [[ "$INFO" != false && "$CHECK_VERSION" == true ]]; then VERSION_CHECK; else echo; fi
}

# Check root
CHECK_ROOT () {
  if [[ "$RICM" != true && "$EUID" -ne 0 ]]; then
      echo -e "\n ${RD}--- Please run this as root ---${CL}\n"
      exit 2
  fi
}

ARGUMENTS () {
  while test $# -gt -0; do
    ARGUMENT="$1"
    case "$ARGUMENT" in
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
      -w)
        WELCOME_SCREEN=true
        ;;
      host)
        COMMAND=true
        if [[ "$RICM" != true ]]; then
          MODE="  Host  "
          HEADER_INFO
        fi
        echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$IP| ($HOSTNAME)${CL}\n"
        if [[ "$WITH_HOST" == true ]]; then
          UPDATE_HOST_ITSELF
        else
          echo -e "${BL}[Info] Skipped host itself by user${CL}\n\n"
        fi
        if [[ "$WITH_LXC" == true ]]; then
          CONTAINER_UPDATE_START
        else
          echo -e "${BL}[Info] Skipped all container by user${CL}\n"
        fi
        if [[ "$WITH_VM" == true ]]; then
          VM_UPDATE_START
        else
          echo -e "${BL}[Info] Skipped all VM by user${CL}\n"
        fi
        ;;
      cluster)
        COMMAND=true
        MODE="Cluster "
        HEADER_INFO
        HOST_UPDATE_START
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        exit 2
        ;;
      master)
        BRANCH=master
        ;;
      beta)
        BRANCH=beta
        ;;
      development)
        BRANCH=development
        ;;
      -up)
        COMMAND=true
        UPDATE
        exit 2
        ;;
      status)
        INFO=false
        HEADER_INFO
        COMMAND=true
        STATUS
        exit 2
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
  if [[ "$HEADLESS" != true ]]; then
    echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
    echo -e "[OPTIONS] Manages the Proxmox-Updater:"
    echo -e "======================================"
    echo -e "  -s --silent          Silent / Headless Mode"
    echo -e "  master               Use master branch"
    echo -e "  beta                 Use beta branch"
    echo -e "  development          Use development branch\n"
    echo -e "{COMMAND}:"
    echo -e "========="
    echo -e "  -h --help            Show this help"
    echo -e "  -v --version         Show Proxmox-Updater Version"
    echo -e "  -up                  Update Proxmox-Updater"
    echo -e "  status               Show Status (Version Infos)"
    echo -e "  uninstall            Uninstall Proxmox-Updater\n"
    echo -e "  host                 Host-Mode"
    echo -e "  cluster              Cluster-Mode\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check / Update Message in Header
VERSION_CHECK () {
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update.sh > /root/Proxmox-Updater/temp/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/update.sh)
  if [[ "$SERVER_VERSION" > "$VERSION" ]]; then
    echo -e "\n${OR}   *** A newer version is available ***${CL}\n\
      Installed: $VERSION / Server: $SERVER_VERSION\n"
    if [[ "$HEADLESS" != true ]]; then
      echo -e "${OR}Want to update Proxmox-Updater first?${CL}"
      read -p "Type [Y/y] or Enter for yes - enything else will skip " -n 1 -r -s
      if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
        bash <(curl -s "$SERVER_URL"/install.sh) update
      fi
      echo
    fi
  elif [[ "$SERVER_VERSION" < "$VERSION" ]]; then
    if [[ "$BRANCH" == beta ]]; then
      echo -e "\n${OR}         *** U are on beta branch ***${CL}\n\
               Version: $VERSION"
    else
      echo -e "\n${OR}     *** U are on development branch ***${CL}\n\
               Version: $VERSION"
    fi
  else
    echo -e "\n             ${GN}Script is UpToDate${CL}\n\
               Version: $VERSION"
  fi
  rm -rf /root/Proxmox-Updater/temp/update.sh && echo
}

# Update Proxmox-Updater
UPDATE () {
  bash <(curl -s "https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"/install.sh) update
}

# Uninstall
UNINSTALL () {
  echo -e "\n${BL}[Info]${OR} Uninstall Proxmox-Updater${CL}\n"
  echo -e "${RD}Really want to remove Proxmox-Updater?${CL}"
  read -p "Type [Y/y] for yes - enything else will exit " -n 1 -r -s
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    bash <(curl -s "$SERVER_URL"/install.sh) uninstall
  else
    exit 2
  fi
}

STATUS () {
  # Get Server Versions
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update.sh > /root/Proxmox-Updater/temp/update.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update-extras.sh > /root/Proxmox-Updater/temp/update-extras.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update.conf > /root/Proxmox-Updater/temp/update.conf
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/update.sh)
  SERVER_EXTRA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/update-extras.sh)
  SERVER_CONFIG_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/update.conf)
  EXTRA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/update-extras.sh)
  CONFIG_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/update.conf)
  if [[ "$WELCOME_SCREEN" == true ]]; then
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/welcome-screen.sh > /root/Proxmox-Updater/temp/welcome-screen.sh
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/check-updates.sh > /root/Proxmox-Updater/temp/check-updates.sh
    SERVER_WELCOME_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/welcome-screen.sh)
    SERVER_CHECK_UPDATE_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/temp/check-updates.sh)
    WELCOME_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /etc/update-motd.d/01-welcome-screen)
    CHECK_UPDATE_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/Proxmox-Updater/check-updates.sh)
  fi
  MODIFICATION=$(curl -s https://api.github.com/repos/BassT23/Proxmox | grep pushed_at | cut -d: -f2- | cut -c 3- | rev | cut -c 3- | rev)
  echo -e "Last modification (on GitHub): $MODIFICATION\n"
  echo -e "${OR}  Version overview ($BRANCH branch)${CL}"
  if [[ "$SERVER_VERSION" != "$VERSION" ]] || [[ "$SERVER_EXTRA_VERSION" != "$EXTRA_VERSION" ]] || [[ "$SERVER_CONFIG_VERSION" != "$CONFIG_VERSION" ]] || [[ "$SERVER_WELCOME_VERSION" != "$WELCOME_VERSION" ]] || [[ "$SERVER_CHECK_UPDATE_VERSION" != "$CHECK_UPDATE_VERSION" ]]; then
    echo -e "           Local / Server\n"
  fi
  if [[ "$SERVER_VERSION" == "$VERSION" ]]; then
    echo -e "  Updater: ${GN}$VERSION${CL}"
  else
    echo -e "  Updater: $VERSION / ${OR}$SERVER_VERSION${CL}"
  fi
  if [[ "$SERVER_EXTRA_VERSION" == "$EXTRA_VERSION" ]]; then
    echo -e "  Extras:  ${GN}$EXTRA_VERSION${CL}"
  else
    echo -e "  Extras:  $EXTRA_VERSION / ${OR}$SERVER_EXTRA_VERSION${CL}"
  fi
  if [[ "$SERVER_CONFIG_VERSION" == "$CONFIG_VERSION" ]]; then
    echo -e "  Config:  ${GN}$CONFIG_VERSION${CL}"
  else
    echo -e "  Config:  $CONFIG_VERSION / ${OR}$SERVER_CONFIG_VERSION${CL}"
  fi
  if [[ "$WELCOME_SCREEN" == true ]]; then
    if [[ "$SERVER_WELCOME_VERSION" == "$WELCOME_VERSION" ]]; then
      echo -e "  Welcome: ${GN}$WELCOME_VERSION${CL}"
    else
      echo -e "  Welcome: $WELCOME_VERSION / ${OR}$SERVER_WELCOME_VERSION${CL}"
    fi
    if [[ "$SERVER_CHECK_UPDATE_VERSION" == "$CHECK_UPDATE_VERSION" ]]; then
      echo -e "  Check:   ${GN}$CHECK_UPDATE_VERSION${CL}"
    else
      echo -e "  Check:   $CHECK_UPDATE_VERSION / ${OR}$SERVER_CHECK_UPDATE_VERSION${CL}"
    fi
  fi
  echo
  rm -r /root/Proxmox-Updater/temp/*.*
}

# Read Config File
READ_CONFIG () {
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' "$CONFIG_FILE")
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  EXTRA_GLOBAL=$(awk -F'"' '/^EXTRA_GLOBAL=/ {print $2}' "$CONFIG_FILE")
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
}

# Extras
EXTRAS () {
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of user settings ---${CL}\n"
  elif [[ "$HEADLESS" == true && "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of Headless Mode or user settings ---${CL}\n"
  else
    echo -e "\n${OR}--- Searching for extra updates ---${CL}"
    if [[ "$SSH_CONNECTION" != true ]]; then
      pct exec "$CONTAINER" -- bash -c "mkdir -p /root/Proxmox-Updater/"
      pct push "$CONTAINER" -- /root/Proxmox-Updater/update-extras.sh /root/Proxmox-Updater/update-extras.sh
      pct push "$CONTAINER" -- /root/Proxmox-Updater/update.conf /root/Proxmox-Updater/update.conf
      pct exec "$CONTAINER" -- bash -c "chmod +x /root/Proxmox-Updater/update-extras.sh && \
                                        /root/Proxmox-Updater/update-extras.sh && \
                                        rm -rf /root/Proxmox-Updater"
    else
      # Extras in VMS with SSH_CONNECTION
      ssh "$IP" mkdir -p /root/Proxmox-Updater/
      scp /root/Proxmox-Updater/update-extras.sh "$IP":/root/Proxmox-Updater/update-extras.sh
      scp /root/Proxmox-Updater/update.conf "$IP":/root/Proxmox-Updater/update.conf
      ssh "$IP" "chmod +x /root/Proxmox-Updater/update-extras.sh && \
                /root/Proxmox-Updater/update-extras.sh && \
                rm -rf /root/Proxmox-Updater"
    fi
    echo -e "${GN}---   Finished extra updates    ---${CL}"
    if [[ "$WILL_STOP" != true ]] && [[ "$WELCOME_SCREEN" != true ]]; then
      echo
    elif [[ "$WELCOME_SCREEN" == true ]]; then
      echo
    fi
  fi
}

# Check Updates for Welcome-Screen
UPDATE_CHECK () {
  if [[ "$WELCOME_SCREEN" == true ]]; then
    echo -e "${OR}--- Check Status for Welcome-Screen ---${CL}"
    if [[ "$CHOST" == true ]]; then
      ssh "$HOSTNAME" "/root/Proxmox-Updater/check-updates.sh -u chost" | tee -a /root/Proxmox-Updater/check-output
    elif [[ "$CCONTAINER" == true ]]; then
      ssh "$HOSTNAME" "/root/Proxmox-Updater/check-updates.sh -u ccontainer" | tee -a /root/Proxmox-Updater/check-output
    elif [[ "$CVM" == true ]]; then
      ssh "$HOSTNAME" "/root/Proxmox-Updater/check-updates.sh -u cvm" | tee -a /root/Proxmox-Updater/check-output
    fi
    echo -e "${GN}---          Finished check         ---${CL}\n"
    if [[ "$WILL_STOP" != true ]]; then echo; fi
  else
    echo
  fi
}

## HOST ##
# Host Update Start
HOST_UPDATE_START () {
  if [[ "$RICM" != true ]]; then true > /root/Proxmox-Updater/check-output; fi
  for HOST in $HOSTS; do
    UPDATE_HOST "$HOST"
  done
}

# Host Update
UPDATE_HOST () {
  HOST=$1
  START_HOST=$(hostname -I | tr -d '[:space:]')
  if [[ "$HOST" != "$START_HOST" ]]; then
    ssh "$HOST" mkdir -p /root/Proxmox-Updater/temp
    scp "$0" "$HOST":/root/Proxmox-Updater/update
    scp /root/Proxmox-Updater/update-extras.sh "$HOST":/root/Proxmox-Updater/update-extras.sh
    scp /root/Proxmox-Updater/update.conf "$HOST":/root/Proxmox-Updater/update.conf
    if [[ "$WELCOME_SCREEN" == true ]]; then
      scp /root/Proxmox-Updater/check-updates.sh "$HOST":/root/Proxmox-Updater/check-updates.sh
      scp /root/Proxmox-Updater/check-output "$HOST":/root/Proxmox-Updater/check-output
      scp ~/Proxmox-Updater/temp/exec_host "$HOST":~/Proxmox-Updater/temp
    fi
    if [[ -d /root/Proxmox-Updater/VMs/ ]]; then
      scp -r /root/Proxmox-Updater/VMs/ "$HOST":/root/Proxmox-Updater/
    fi
  fi
  if [[ "$HEADLESS" == true ]]; then
    ssh "$HOST" 'bash -s' < "$0" -- "-s -c host"
  elif [[ "$WELCOME_SCREEN" == true ]]; then
    ssh "$HOST" 'bash -s' < "$0" -- "-c -w host"
  else
    ssh "$HOST" 'bash -s' < "$0" -- "-c host"
  fi
}

UPDATE_HOST_ITSELF () {
  echo -e "${OR}--- APT UPDATE ---${CL}" && apt-get update
  if [[ "$HEADLESS" == true ]]; then
    echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}" && \
            DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
  else
    echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
            apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
  fi
  echo -e "\n${OR}--- APT CLEANING ---${CL}" && \
          apt-get --purge autoremove -y && echo
  CHOST="true"
  UPDATE_CHECK
  CHOST=""
}

## Container ##
# Container Update Start
CONTAINER_UPDATE_START () {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    if [[ "$ONLY" == "" && "$EXCLUDED" =~ $CONTAINER ]]; then
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $CONTAINER ]]; then
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by user${CL}\n\n"
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED" == true ]]; then
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
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED" != true ]]; then
        echo -e "${BL}[Info] Skipped LXC $CONTAINER by user${CL}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING" == true ]]; then
        UPDATE_CONTAINER "$CONTAINER"
      elif [[ "$STATUS" == "status: running" && "$RUNNING" != true ]]; then
        echo -e "${BL}[Info] Skipped LXC $CONTAINER by user${CL}\n\n"
      fi
    fi
  done
  rm -rf ~/Proxmox-Updater/temp/temp
}

# Container Update
UPDATE_CONTAINER () {
  CONTAINER=$1
  CCONTAINER="true"
  echo 'CONTAINER="'"$CONTAINER"'"' > ~/Proxmox-Updater/temp/var
  pct config "$CONTAINER" > ~/Proxmox-Updater/temp/temp
  OS=$(awk '/^ostype/' ~/Proxmox-Updater/temp/temp | cut -d' ' -f2)
  if [[ "$OS" =~ centos ]]; then
    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
  else
    NAME=$(pct exec "$CONTAINER" hostname)
  fi
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    echo -e "${OR}--- APT UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "apt-get update"
    if [[ "$HEADLESS" == true ]]; then
      echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
    fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y"
      EXTRAS
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
    echo -e "${OR}--- DNF UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "dnf -y update"
    echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "dnf -y upgrade"
    echo -e "\n${OR}--- DNF CLEANING ---${CL}"
    pct exec "$CONTAINER" -- bash -c "dnf -y autoremove"
    EXTRAS
    UPDATE_CHECK
  elif [[ "$OS" =~ archlinux ]]; then
    echo -e "${OR}--- PACMAN UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "pacman -Syyu --noconfirm"
    EXTRAS
    UPDATE_CHECK
  elif [[ "$OS" =~ alpine ]]; then
    echo -e "${OR}--- APK UPDATE ---${CL}"
    pct exec "$CONTAINER" -- ash -c "apk -U upgrade"
    if [[ "$WILL_STOP" != true ]]; then echo; fi
    echo
  else
    echo -e "${OR}--- YUM UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "yum -y update"
    EXTRAS
    UPDATE_CHECK
  fi
  CCONTAINER=""
}

## VM ##
# VM Update Start
VM_UPDATE_START () {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through the VMs
  for VM in $VMS; do
    PRE_OS=$(qm config "$VM" | grep 'ostype:' | sed 's/ostype:\s*//')
    if [[ "$ONLY" == "" && "$EXCLUDED" =~ $VM ]]; then
      echo -e "${BL}[Info] Skipped VM $VM by user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $VM ]]; then
      echo -e "${BL}[Info] Skipped VM $VM by user${CL}\n\n"
    elif [[ "$PRE_OS" =~ w ]]; then
      echo -e "${BL}[Info] Skipped VM $VM${CL}\n"
      echo -e "${OR}  Windows is not supported for now.\n  I'm working on it ;)${CL}\n\n"
    else
      STATUS=$(qm status "$VM")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED" == true ]]; then
        # Check if update is possiple
        if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 ]] || [[ -f /root/Proxmox-Updater/VMs/"$VM" ]]; then
          # Start the VM
          WILL_STOP="true"
          echo -e "${BL}[Info]${GN} Starting VM${BL} $VM ${CL}"
          qm set "$VM" --agent 1 >/dev/null 2>&1
          qm start "$VM" >/dev/null 2>&1
          echo -e "${BL}[Info]${GN} Waiting for VM${BL} $VM${CL}${GN} to start${CL}"
          echo -e "${OR}This will take some time, ... 45 secounds is set!${CL}"
          sleep 45
          UPDATE_VM "$VM"
          # Stop the VM
          echo -e "${BL}[Info]${GN} Shutting down VM${BL} $VM ${CL}\n\n"
          qm stop "$VM" &
          WILL_STOP="false"
        else
          echo -e "${BL}[Info] Skipped VM $VM because, QEMU or SSH not initialized${CL}\n\n"
          return
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by user${CL}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING" == true ]]; then
        UPDATE_VM "$VM"
      elif [[ "$STATUS" == "status: running" && "$RUNNING" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by user${CL}\n\n"
      fi
    fi
  done
}

# VM Update
# SSH
UPDATE_VM () {
  VM=$1
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  CVM="true"
  echo 'VM="'"$VM"'"' > ~/Proxmox-Updater/temp/var
  echo -e "${BL}[Info]${GN} Updating VM ${BL}$VM${CL} : ${GN}$NAME${CL}\n"
  if [[ -f /root/Proxmox-Updater/VMs/"$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' /root/Proxmox-Updater/VMs/"$VM")
    if ! (ssh "$IP" exit >/dev/null 2>&1); then
      echo -e "${RD}  File for ssh connection found, but not correctly set?\n\
  Please configure SSH Key-Based Authentication${CL}\n\
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>
  Try to use QEMU insead\n"
      UPDATE_VM_QEMU
    else
      SSH_CONNECTION=true
      OS_BASE=$(qm config "$VM" | grep ostype)
      if [[ "$OS_BASE" =~ l2 ]]; then
        OS=$(ssh "$IP" hostnamectl | grep System)
        if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
          echo -e "${OR}--- APT UPDATE ---${CL}"
          ssh "$IP" apt-get update
          echo -e "\n${OR}--- APT UPGRADE ---${CL}"
          ssh "$IP" apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y
          echo -e "\n${OR}--- APT CLEANING ---${CL}"
          ssh "$IP" apt-get --purge autoremove -y
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Fedora ]]; then
          echo -e "${OR}--- DNF UPDATE ---${CL}"
          ssh "$IP" dnf -y update
          echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
          ssh "$IP" dnf -y upgrade
          echo -e "\n${OR}--- DNF CLEANING ---${CL}"
          ssh "$IP" dnf -y --purge autoremove
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Arch ]]; then
          echo -e "${OR}--- PACMAN UPDATE ---${CL}"
          ssh "$IP" pacman -Syyu --noconfirm
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Alpine ]]; then
          echo -e "${OR}--- APK UPDATE ---${CL}"
          ssh "$IP" apk -U upgrade
        elif [[ "$OS" =~ CentOS ]]; then
          echo -e "${OR}--- YUM UPDATE ---${CL}"
          ssh "$IP" yum -y update
          EXTRAS
          UPDATE_CHECK
        else
          echo -e "${RD}  System is not supported.\n  Maybe with later version ;)\n${CL}"
          echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
        fi
        return
#      elif [[ $OS_BASE == win10 ]]; then
#        ssh "$USER"@"$IP" wuauclt /detectnow /updatenow
#        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot # don't work
      fi
    fi
  else
    UPDATE_VM_QEMU
  fi
}

# QEMU
UPDATE_VM_QEMU () {
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    echo -e "${OR}  QEMU found. SSH connection is also available - with better output.${CL}\n\
  Please look here: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n"
    OS=$(qm guest cmd "$VM" get-osinfo | grep name)
    if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
      echo -e "${OR}--- APT UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get update" | tail -n +4 | head -n -1 | cut -c 17-
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      qm guest exec "$VM" --timeout 120 -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +2 | head -n -1
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1 | cut -c 17-
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Fedora ]]; then
      echo -e "${OR}--- DNF UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "dnf -y update" | tail -n +4 | head -n -1 | cut -c 17-
      echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
      qm guest exec "$VM" -- bash -c "dnf -y upgrade" | tail -n +2 | head -n -1
      echo -e "\n${OR}--- DNF CLEANING ---${CL}"
      qm guest exec "$VM" -- bash -c "dnf -y --purge autoremove" | tail -n +4 | head -n -1 | cut -c 17-
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Arch ]]; then
      echo -e "${OR}--- PACMAN UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "pacman -Syyu --noconfirm" | tail -n +2 | head -n -1
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Alpine ]]; then
      echo -e "${OR}--- APK UPDATE ---${CL}"
      qm guest exec "$VM" -- ash -c "apk -U upgrade" | tail -n +2 | head -n -1
    elif [[ "$OS" =~ CentOS ]]; then
      echo -e "${OR}--- YUM UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "yum -y update" | tail -n +2 | head -n -1
      echo
      UPDATE_CHECK
    else
      echo -e "${RD}  System is not supported.\n  Maybe with later version ;)\n${CL}"
      echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
  else
    echo -e "${RD}  SSH or QEMU guest agent is not initialized on VM ${CL}\n\
  ${OR}If you want to update VM, you must set up it by yourself!${CL}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
  fi
  CVM=""
}

## General ##
# Logging
OUTPUT_TO_FILE () {
  if [[ "$RICM" != true ]]; then
    touch "$LOG_FILE"
    exec &> >(tee "$LOG_FILE")
  fi
  # Welcome-Screen
  if [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
    WELCOME_SCREEN=true
    if [[ "$RICM" != true ]]; then
      echo 'EXEC_HOST="'"$HOSTNAME"'"' > ~/Proxmox-Updater/temp/exec_host
      touch /root/Proxmox-Updater/check-output
    fi
  fi
}

CLEAN_LOGFILE () {
  if [[ "$RICM" != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
    cat $LOG_FILE | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE" >/dev/null 2>&1
    chmod 640 "$LOG_FILE"
    if [[ -f ./tmp.log ]]; then
      rm -rf ./tmp.log
    fi
  fi
}

# Exit
EXIT () {
  EXIT_CODE=$?
  EXEC_HOST=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' ~/Proxmox-Updater/temp/exec_host)
  scp /root/Proxmox-Updater/check-output "$EXEC_HOST":/root/Proxmox-Updater/check-output
  # Exit without echo
  if [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "$RICM" != true ]]; then
      echo -e "${GN}Finished, All Updates Done.${CL}\n"
      /root/Proxmox-Updater/exit/passed.sh
      CLEAN_LOGFILE
    fi
  else
  # Update Error
    if [[ "$RICM" != true ]]; then
      echo -e "${RD}Error during Update --- Exit Code: $EXIT_CODE${CL}\n"
      /root/Proxmox-Updater/exit/error.sh
      CLEAN_LOGFILE
    fi
  fi
  sleep 3
  rm -rf ~/Proxmox-Updater/temp/var
  rm -rf /root/Proxmox-Updater/update
  if [[ "$HOSTNAME" != "$EXEC_HOST" ]]; then rm -rf /root/Proxmox-Updater; fi
}
set -e
trap EXIT EXIT

# Check Cluster Mode
if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster "
else
  MODE="  Host  "
fi

# Run
export TERM=xterm-256color
if ! [[ -d ~/Proxmox-Updater/temp ]]; then mkdir ~/Proxmox-Updater/temp; fi
READ_CONFIG
OUTPUT_TO_FILE
IP=$(hostname -I)
ARGUMENTS "$@"

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true ]]; then
  HEADER_INFO
  if [[ "$MODE" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$IP| ($HOSTNAME)${CL}"
    if [[ "$WITH_HOST" == true ]]; then
      UPDATE_HOST_ITSELF
    else
      echo -e "${BL}[Info] Skipped host itself by user${CL}\n\n"
    fi
    if [[ "$WITH_LXC" == true ]]; then
      CONTAINER_UPDATE_START
    else
      echo -e "${BL}[Info] Skipped all container by user${CL}\n"
    fi
    if [[ "$WITH_VM" == true ]]; then
      VM_UPDATE_START
    else
      echo -e "${BL}[Info] Skipped all VMs by user${CL}\n"
    fi
  fi
fi

exit 0
