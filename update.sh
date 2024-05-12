#!/bin/bash

##########
# Update #
##########

# shellcheck disable=SC2034
# shellcheck disable=SC2029
# shellcheck disable=SC2317
# shellcheck disable=SC2320
VERSION="4.1.5"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
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
    https://github.com/BassT23/Proxmox\n"
  cat <<'EOF'
 The __  ______  _                 __
    / / / / / /_(_)___ ___  ____ _/ /____
   / / / / / __/ / __ `__ \/ __ `/ __/ _ \
  / /_/ / / /_/ / / / / / / /_/ / /_/  __/
  \____/_/\__/_/_/ /_/ /_/\____/\__/\___/
     __  __          __      __
    / / / /___  ____/ /___ _/ /____  ____
   / / / / __ \/ __  / __ `/ __/ _ \/ __/
  / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
  \____/ ____/\____/\____/\__/\___/_/
      /_/     for Proxmox VE
EOF
  if [[ "$INFO" != false ]]; then
    echo -e "\n \
          ***  Mode: $MODE***"
    if [[ "$HEADLESS" == true ]]; then
      echo -e "           ***    Headless    ***"
    else
      echo -e "           ***   Interactive  ***"
    fi
  fi
  CHECK_ROOT
  CHECK_INTERNET
  if [[ "$INFO" != false && "$CHECK_VERSION" == true ]]; then VERSION_CHECK; else echo; fi
}

# Name Changing
NAME_CHANGING () {
if [[ -d /root/Proxmox-Updater/ ]]; then mv /root/Proxmox-Updater/ $LOCAL_FILES/; fi
}

# Check root
CHECK_ROOT () {
  if [[ "$RICM" != true && "$EUID" -ne 0 ]]; then
      echo -e "\n${RD} --- Please run this as root ---${CL}\n"
      exit 2
  fi
}

# Check internet status
CHECK_INTERNET () {
  if ! ping -q -c1 "$CHECK_URL" &>/dev/null; then
    echo -e "\n${OR} You are offline - Can't update without internet${CL}\n"
    exit 2
  fi
}

ARGUMENTS () {
  while test $# -gt -0; do
    ARGUMENT="$1"
    case "$ARGUMENT" in
      [0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])
        COMMAND=true
        SINGLE_UPDATE=true
        ONLY=$ARGUMENT
        HEADER_INFO
        CONTAINER_UPDATE_START
#        echo -e "update only LXC/VM $ARGUMENT - in future :)"
        ;;
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
          echo -e "${BL}[Info] Skipped host itself by the user${CL}\n\n"
        fi
        if [[ "$WITH_LXC" == true ]]; then
          CONTAINER_UPDATE_START
        else
          echo -e "${BL}[Info] Skipped all containers by the user${CL}\n"
        fi
        if [[ "$WITH_VM" == true ]]; then
          VM_UPDATE_START
        else
          echo -e "${BL}[Info] Skipped all VMs by the user${CL}\n"
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
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR}  Wrong usage! Use branch update like this:${CL}"
          echo -e "  update beta -up\n"
          exit 2
        fi
        BRANCH=master
        BRANCH_SET=true
        ;;
      beta)
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR}  Wrong usage! Use branch update like this:${CL}"
          echo -e "  update beta -up\n"
          exit 2
        fi
        BRANCH=beta
        BRANCH_SET=true
        ;;
      develop)
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR}  Wrong usage! Use branch update like this:${CL}"
          echo -e "  update beta -up\n"
          exit 2
        fi
        BRANCH=develop
        BRANCH_SET=true
        ;;
      -up)
        COMMAND=true
        if [[ "$BRANCH_SET" != true ]]; then
          BRANCH=master
        fi
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
        echo -e "\n${RD} Error: Got an unexpected argument \"$ARGUMENT\"${CL}";
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
    echo -e "[OPTIONS] Manages the Ultimate Updater:"
    echo -e "======================================"
    echo -e "  -s --silent          Silent / Headless Mode"
    echo -e "  master               Use master branch"
    echo -e "  beta                 Use beta branch"
    echo -e "  develop              Use develop branch\n"
    echo -e "{COMMAND}:"
    echo -e "========="
    echo -e "  -h --help            Show help menu"
    echo -e "  -v --version         Show The Ultimate Updater version"
    echo -e "  -up                  Update The Ultimate Updater"
    echo -e "  status               Show Status (Version Infos)"
    echo -e "  uninstall            Uninstall The Ultimate Updater\n"
    echo -e "  host                 Host-Mode"
    echo -e "  cluster              Cluster-Mode\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check / Update Message in Header
VERSION_CHECK () {
  curl -s "$SERVER_URL"/update.sh > $LOCAL_FILES/temp/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update.sh)
  if [[ "$BRANCH" == beta ]]; then
    echo -e "\n${OR}       *** You are on beta branch ***${CL}"
  elif [[ "$BRANCH" == develop ]]; then
    echo -e "\n${OR}     *** You are on develop branch ***${CL}"
  fi
  if [[ "$SERVER_VERSION" > "$VERSION" ]]; then
    echo -e "\n${OR}    *** A newer version is available ***${CL}\n\
      Installed: $VERSION / Server: $SERVER_VERSION\n"
    if [[ "$HEADLESS" != true ]]; then
      echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
      read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
      if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
        bash <(curl -s "$SERVER_URL"/install.sh) update
      fi
      echo
    fi
    VERSION_NOT_SHOW=true
  elif [[ "$BRANCH" == master ]]; then
      echo -e "\n              ${GN}Script is UpToDate${CL}"
  fi
  if [[ "$VERSION_NOT_SHOW" != true ]]; then echo -e "                 Version: $VERSION"; fi
  rm -rf $LOCAL_FILES/temp/update.sh && echo
}


# Update The Ultimate Updater
UPDATE () {
  echo -e "Update to $BRANCH branch?"
  read -p "Type [Y/y] or [Enter] for yes - anything else will exit: " -r
  if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
    bash <(curl -s "https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"/install.sh) update
  else
    exit 2
  fi
}

# Uninstall
UNINSTALL () {
  echo -e "\n${BL}[Info]${OR} Uninstall The Ultimate Updater${CL}\n"
  echo -e "${RD}Really want to remove The Ultimate Updater?${CL}"
  read -p "Type [Y/y] for yes - anything else will exit: " -r
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    bash <(curl -s "$SERVER_URL"/install.sh) uninstall
    exit 2
  else
    exit 2
  fi
}

STATUS () {
  # Get Server Versions
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update.sh > $LOCAL_FILES/temp/update.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update-extras.sh > $LOCAL_FILES/temp/update-extras.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/update.conf > $LOCAL_FILES/temp/update.conf
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update.sh)
  SERVER_EXTRA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update-extras.sh)
  SERVER_CONFIG_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update.conf)
  EXTRA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/update-extras.sh)
  CONFIG_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/update.conf)
  if [[ "$WELCOME_SCREEN" == true ]]; then
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/welcome-screen.sh > $LOCAL_FILES/temp/welcome-screen.sh
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/"$BRANCH"/check-updates.sh > $LOCAL_FILES/temp/check-updates.sh
    SERVER_WELCOME_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/welcome-screen.sh)
    SERVER_CHECK_UPDATE_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/check-updates.sh)
    WELCOME_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /etc/update-motd.d/01-welcome-screen)
    CHECK_UPDATE_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/check-updates.sh)
  fi
  MODIFICATION=$(curl -s https://api.github.com/repos/BassT23/Proxmox | grep pushed_at | cut -d: -f2- | cut -c 3- | rev | cut -c 3- | rev)
  echo -e "Last modification (on GitHub): $MODIFICATION\n"
  if [[ "$BRANCH" == master ]]; then echo -e "${OR}  Version overview${CL}"; else
    echo -e "${OR}  Version overview ($BRANCH)${CL}"
  fi
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
  rm -r $LOCAL_FILES/temp/*.*
}

# Read Config File
READ_CONFIG () {
  LOG_FILE=$(awk -F'"' '/^LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL=$(awk -F'"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' "$CONFIG_FILE")
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING_CONTAINER=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED_CONTAINER=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  RUNNING_VM=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$CONFIG_FILE")
  STOPPED_VM=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$CONFIG_FILE")
#  INCLUDE_KERNEL=$(awk -F'"' '/^INCLUDE_KERNEL=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_PHASED_UPDATES=$(awk -F'"' '/^INCLUDE_PHASED_UPDATES=/ {print $2}' "$CONFIG_FILE")
  SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT=$(awk -F'"' '/^KEEP_SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "$CONFIG_FILE")
  VM_START_DELAY=$(awk -F'"' '/^VM_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  EXTRA_GLOBAL=$(awk -F'"' '/^EXTRA_GLOBAL=/ {print $2}' "$CONFIG_FILE")
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
}

# Snapshot/Backup
CONTAINER_BACKUP () {
  if [[ "$SNAPSHOT" == true ]] || [[ "$BACKUP" == true ]]; then
    if [[ "$SNAPSHOT" == true ]]; then
      if pct snapshot "$CONTAINER" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "${BL}[Info]${GN} Snapshot created${CL}"
        echo -e "${BL}[Info]${GN} Deleted old snapshots${CL}"
        LIST=$(pct listsnapshot "$CONTAINER" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          pct delsnapshot "$CONTAINER" Update"$SNAPSHOTS"
        done
      echo -e "${BL}[Info]${GN} Done${CL}"
      else
        echo -e "${BL}[Info]${RD} Snapshot is not possible on your storage${CL}"
      fi
    fi
    if [[ "$BACKUP" == true ]]; then
      echo -e "${BL}[Info] Create a backup for LXC (this will take some time - please wait)${CL}"
      vzdump "$CONTAINER" --mode stop --storage "$(pvesm status -content backup | grep -m 1 -v ^Name | cut -d ' ' -f1)" --compress zstd
      echo -e "${BL}[Info]${GN} Backup created${CL}\n"
    fi
  else
    echo -e "${BL}[Info]${OR} Snapshot and Backup skipped by the user${CL}"
  fi
}
VM_BACKUP () {
  if [[ "$SNAPSHOT" == true ]] || [[ "$BACKUP" == true ]]; then
    if [[ "$SNAPSHOT" == true ]]; then
      if qm snapshot "$VM" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "${BL}[Info]${GN} Snapshot created${CL}"
        echo -e "${BL}[Info]${GN} Deleting old snapshot(s)${CL}"
        LIST=$(qm listsnapshot "$VM" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          qm delsnapshot "$VM" Update"$SNAPSHOTS"
        done
      echo -e "${BL}[Info]${GN} Done${CL}"
      else
        echo -e "${BL}[Info]${RD} Snapshot is not possible on your storage${CL}"
      fi
    fi
    if [[ "$BACKUP" == true ]]; then
      echo -e "${BL}[Info] Create a backup for the VM (this will take some time - please wait)${CL}"
      vzdump "$VM" --mode stop --storage "$(pvesm status -content backup | grep -m 1 -v ^Name | cut -d ' ' -f1)" --compress zstd
      echo -e "${BL}[Info]${GN} Backup created${CL}"
    fi
  else
    echo -e "${BL}[Info]${OR} Snapshot and/or Backup skipped by the user${CL}"
  fi
}

# Extras
EXTRAS () {
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of the user settings ---${CL}\n"
  elif [[ "$HEADLESS" == true && "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of Headless Mode or the user settings ---${CL}\n"
  else
    echo -e "\n${OR}--- Searching for extra updates ---${CL}"
    if [[ "$SSH_CONNECTION" != true ]]; then
      pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/"
      pct push "$CONTAINER" -- $LOCAL_FILES/update-extras.sh $LOCAL_FILES/update-extras.sh
      pct push "$CONTAINER" -- $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/update-extras.sh && \
                                        $LOCAL_FILES/update-extras.sh && \
                                        rm -rf $LOCAL_FILES"
    else
      # Extras in VMS with SSH_CONNECTION
      ssh -q -p "$SSH_PORT" "$IP" mkdir -p $LOCAL_FILES/
      scp $LOCAL_FILES/update-extras.sh "$IP":$LOCAL_FILES/update-extras.sh
      scp $LOCAL_FILES/update.conf "$IP":$LOCAL_FILES/update.conf
      ssh -q -p "$SSH_PORT" "$IP" "chmod +x $LOCAL_FILES/update-extras.sh && \
                $LOCAL_FILES/update-extras.sh && \
                rm -rf $LOCAL_FILES"
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
      ssh -q -p "$SSH_PORT" "$HOSTNAME" $LOCAL_FILES/check-updates.sh -u chost | tee -a $LOCAL_FILES/check-output
    elif [[ "$CCONTAINER" == true ]]; then
      ssh -q -p "$SSH_PORT" "$HOSTNAME" $LOCAL_FILES/check-updates.sh -u ccontainer | tee -a $LOCAL_FILES/check-output
    elif [[ "$CVM" == true ]]; then
      ssh -q -p "$SSH_PORT" "$HOSTNAME" $LOCAL_FILES/check-updates.sh -u cvm | tee -a $LOCAL_FILES/check-output
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
  if [[ "$RICM" != true ]]; then true > $LOCAL_FILES/check-output; fi
  for HOST in $HOSTS; do
    # Check if Host/Node is available
    if ssh -q -p "$SSH_PORT" "$HOST" test >/dev/null 2>&1; [ $? -eq 255 ]; then
      echo -e "${BL}[Info] ${OR}Skip Host${CL} : ${GN}$HOST${CL} ${OR}- can't connect${CL}\n"
    else
     UPDATE_HOST "$HOST"
    fi
  done
}

# Host Update
UPDATE_HOST () {
  HOST=$1
  START_HOST=$(hostname -I | tr -d '[:space:]')
  if [[ "$HOST" != "$START_HOST" ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" mkdir -p $LOCAL_FILES/temp
    scp "$0" "$HOST":$LOCAL_FILES/update
    scp $LOCAL_FILES/update-extras.sh "$HOST":$LOCAL_FILES/update-extras.sh
    scp $LOCAL_FILES/update.conf "$HOST":$LOCAL_FILES/update.conf
    if [[ "$WELCOME_SCREEN" == true ]]; then
      scp $LOCAL_FILES/check-updates.sh "$HOST":$LOCAL_FILES/check-updates.sh
      if [[ "$WELCOME_SCREEN" == true ]]; then
        scp $LOCAL_FILES/check-output "$HOST":$LOCAL_FILES/check-output
      fi
    fi
    scp /etc/ultimate-updater/temp/exec_host "$HOST":/etc/ultimate-updater/temp
    scp -r $LOCAL_FILES/VMs/ "$HOST":$LOCAL_FILES/
  fi
  if [[ "$HEADLESS" == true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-s -c host"
  elif [[ "$WELCOME_SCREEN" == true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-c -w host"
  else
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-c host"
  fi
}

UPDATE_HOST_ITSELF () {
  echo -e "${OR}--- APT UPDATE ---${CL}" && apt-get update
  if [[ "$HEADLESS" == true ]]; then
    echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}" && \
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y
  else
    if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
      echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
      apt-get dist-upgrade -y
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
      apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
    fi
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
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $CONTAINER ]]; then
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" == true ]]; then
        # Start the container
        WILL_STOP="true"
        echo -e "${BL}[Info]${GN} Starting LXC ${BL}$CONTAINER ${CL}"
        pct start "$CONTAINER"
        echo -e "${BL}[Info]${GN} Waiting for LXC ${BL}$CONTAINER${CL}${GN} to start ${CL}"
        sleep 5
        UPDATE_CONTAINER "$CONTAINER"
        # Stop the container
        echo -e "${BL}[Info]${GN} Shutting down LXC ${BL}$CONTAINER ${CL}\n\n"
        pct shutdown "$CONTAINER" &
        WILL_STOP="false"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" != true ]]; then
        echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" == true ]]; then
        UPDATE_CONTAINER "$CONTAINER"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" != true ]]; then
        echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"
      fi
    fi
  done
  rm -rf /etc/ultimate-updater/temp/temp
}

# Container Update
UPDATE_CONTAINER () {
  CONTAINER=$1
  CCONTAINER="true"
  echo 'CONTAINER="'"$CONTAINER"'"' > /etc/ultimate-updater/temp/var
  pct config "$CONTAINER" > /etc/ultimate-updater/temp/temp
  OS=$(awk '/^ostype/' /etc/ultimate-updater/temp/temp | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
#  if [[ "$OS" =~ centos ]]; then
#    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
#  else
#    NAME=$(pct exec "$CONTAINER" hostname)
#  fi
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  # Check Internet connection
  if [[ "$OS" != alpine ]]; then
    if ! pct exec "$CONTAINER" -- bash -c "ping -q -c1 $CHECK_URL &>/dev/null"; then
      echo -e "${OR} Internet is not reachable - skip the update${CL}\n"
      return
    fi
#  elif [[ "$OS" == alpine ]]; then
#    if ! pct exec "$CONTAINER" -- ash -c "ping -q -c1 $CHECK_URL &>/dev/null"; then
#      echo -e "${OR} Internet is not reachable - skip the update${CL}\n"
#      return
#    fi
  fi
  # Backup
  echo -e "${BL}[Info]${OR} Start Snaphot and/or Backup${CL}"
  CONTAINER_BACKUP
  echo
  # Run update
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    echo -e "${OR}--- APT UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "apt-get update"
    if [[ "$HEADLESS" == true ]]; then
      echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        pct exec "$CONTAINER" -- bash -c "apt-get dist-upgrade -y"
      else
        pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
      fi
    fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y"
      EXTRAS
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
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
      echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $VM ]]; then
      echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
    elif [[ "$PRE_OS" =~ w ]]; then
      echo -e "${BL}[Info] Skipped VM $VM${CL}\n"
      echo -e "${OR}  Windows is not supported for now.\n  I'm working on it ;)${CL}\n\n"
    else
      STATUS=$(qm status "$VM")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
        # Check if update is possible
        if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 ]] || [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
          # Start the VM
          WILL_STOP="true"
          echo -e "${BL}[Info]${GN} Starting VM${BL} $VM ${CL}"
          qm start "$VM" >/dev/null 2>&1
          START_WAITING="true"
          UPDATE_VM "$VM"
          # Stop the VM
          echo -e "${BL}[Info]${GN} Shutting down VM${BL} $VM ${CL}\n\n"
          qm stop "$VM" &
          WILL_STOP="false"
        else
          echo -e "${BL}[Info] Skipped VM $VM because, QEMU or SSH hasn't initialized${CL}\n\n"
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
        UPDATE_VM "$VM"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
      fi
    fi
  done
}

# VM Update
UPDATE_VM () {
  VM=$1
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  CVM="true"
  echo 'VM="'"$VM"'"' > /etc/ultimate-updater/temp/var
  echo -e "${BL}[Info]${GN} Updating VM ${BL}$VM${CL} : ${GN}$NAME${CL}\n"
  # Backup
  echo -e "${BL}[Info]${OR} Start Snaphot and/or Backup${CL}"
  VM_BACKUP
  echo
# Run Update - Tryout SSH first
  if [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    if ! (ssh -q -p "$SSH_PORT" "$IP" exit >/dev/null 2>&1); then
      echo -e "${RD}  File for ssh connection found, but not correctly set?\n\
  Please configure SSH Key-Based Authentication${CL}\n\
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>
  Try to use QEMU insead\n"
      UPDATE_VM_QEMU
    else
      if [[ "$START_WAITING" == true ]]; then
        echo -e "${BL}[Info]${GN} Try to connect via SSH${CL}"
        echo -e "${OR}This will take some time, please wait${CL}"
        echo -e "${OR}!!! During development, sleep $VM_START_DELAY secounds - could be set in config !!!${CL}"
        sleep "$VM_START_DELAY"
      fi
      SSH_CONNECTION=true
      OS_BASE=$(qm config "$VM" | grep ostype)
      if [[ "$OS_BASE" =~ l2 ]]; then
        OS=$(ssh -q -p "$SSH_PORT" "$IP" hostnamectl | grep System)
        if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
          # Check Internet connection
          if ! ssh -q -p "$SSH_PORT" "$IP" ping -q -c1 "$CHECK_URL" &>/dev/null; then
            echo -e "${OR} Internet is not reachable - skip the update${CL}\n"
            return
          fi
          echo -e "${OR}--- APT UPDATE ---${CL}"
          ssh -q -p "$SSH_PORT" "$IP" apt-get update
          echo -e "\n${OR}--- APT UPGRADE ---${CL}"
          if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
            ssh -q -p "$SSH_PORT" -tt "$IP" apt-get upgrade -y
          else
            ssh -q -p "$SSH_PORT" -tt "$IP" apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y
          fi
          echo -e "\n${OR}--- APT CLEANING ---${CL}"
          ssh -q -p "$SSH_PORT" -tt "$IP" apt-get --purge autoremove -y
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Fedora ]]; then
          echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
          ssh -q -p "$SSH_PORT" -tt "$IP" dnf -y upgrade
          echo -e "\n${OR}--- DNF CLEANING ---${CL}"
          ssh -q -p "$SSH_PORT" "$IP" dnf -y --purge autoremove
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Arch ]]; then
          echo -e "${OR}--- PACMAN UPDATE ---${CL}"
          ssh -q -p "$SSH_PORT" -tt "$IP" pacman -Syyu --noconfirm
          EXTRAS
          UPDATE_CHECK
        elif [[ "$OS" =~ Alpine ]]; then
          echo -e "${OR}--- APK UPDATE ---${CL}"
          ssh -q -p "$SSH_PORT" -tt "$IP" apk -U upgrade
        elif [[ "$OS" =~ CentOS ]]; then
          echo -e "${OR}--- YUM UPDATE ---${CL}"
          ssh -q -p "$SSH_PORT" -tt "$IP" yum -y update
          EXTRAS
          UPDATE_CHECK
        else
          echo -e "${RD}  The system is not supported.\n  Maybe with later version ;)\n${CL}"
          echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
        fi
        return
#      elif [[ $OS_BASE == win10 ]]; then
#        ssh -q -p "$SSH_PORT" "$USER"@"$IP" wuauclt /detectnow /updatenow
#        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot # don't work
      fi
    fi
  else
    UPDATE_VM_QEMU
  fi
}

# QEMU
UPDATE_VM_QEMU () {
  if [[ "$START_WAITING" == true ]]; then
    echo -e "${BL}[Info]${GN} Try to connect via QEMU${CL}"
    echo -e "${OR}$VM_START_DELAY secounds wait time - could be set in config\n${CL}"
    sleep "$VM_START_DELAY"
  fi
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    echo -e "${OR}  QEMU found. SSH connection is also available - with better output.${CL}\n\
  Please look here: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n"
    # Run Update
    OS=$(qm guest cmd "$VM" get-osinfo | grep name)
    if [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
      # Check Internet connection
      if ! qm guest exec "$VM" -- bash -c "ping -q -c1 $CHECK_URL &>/dev/null"; then
        echo -e "${OR} Internet is not reachable - skip the update${CL}\n"
        return
      fi
      echo -e "${OR}--- APT UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get update" | tail -n +4 | head -n -1 | cut -c 17-
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        qm guest exec "$VM" --timeout 120 -- bash -c "apt-get upgrade -y" | tail -n +2 | head -n -1
      else
        qm guest exec "$VM" --timeout 120 -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +2 | head -n -1
      fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1 | cut -c 17-
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Fedora ]]; then
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
      echo -e "${RD}  The system is not supported.\n  Maybe with later version ;)\n${CL}"
      echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
  else
    echo -e "${RD}  SSH or QEMU guest agent is not initialized on VM ${CL}\n\
  ${OR}If you want to update VMs, you must set up it by yourself!${CL}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
  fi
  CVM=""
}

## General ##
# Logging
OUTPUT_TO_FILE () {
  echo 'EXEC_HOST="'"$HOSTNAME"'"' > /etc/ultimate-updater/temp/exec_host
  if [[ "$RICM" != true ]]; then
    touch "$LOG_FILE"
    exec &> >(tee "$LOG_FILE")
  fi
  # Welcome-Screen
  if [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
    WELCOME_SCREEN=true
    if [[ "$RICM" != true ]]; then
      touch $LOCAL_FILES/check-output
    fi
  fi
}

CLEAN_LOGFILE () {
  if [[ "$RICM" != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
    # shellcheck disable=SC2002
    cat "$LOG_FILE" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE" >/dev/null 2>&1
    chmod 640 "$LOG_FILE"
    if [[ -f ./tmp.log ]]; then
      rm -rf ./tmp.log
    fi
  fi
}

# shellcheck disable=SC2086
# Exit
EXIT () {
  EXIT_CODE=$?
  if [[ -f "/etc/ultimate-updater/temp/exec_host" ]]; then
    EXEC_HOST=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' /etc/ultimate-updater/temp/exec_host)
  fi
  if [[ "$WELCOME_SCREEN" == true ]]; then
    scp $LOCAL_FILES/check-output "$EXEC_HOST":$LOCAL_FILES/check-output
  fi
  # Exit without echo
  if [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "$RICM" != true ]]; then
      echo -e "${GN}Finished, All Updates Done.${CL}\n"
      $LOCAL_FILES/exit/passed.sh
      CLEAN_LOGFILE
    fi
  else
  # Update Error
    if [[ "$RICM" != true ]]; then
      echo -e "${RD}Error during Update --- Exit Code: $EXIT_CODE${CL}\n"
      $LOCAL_FILES/exit/error.sh
      CLEAN_LOGFILE
    fi
  fi
  sleep 3
  rm -rf /etc/ultimate-updater/temp/var
  rm -rf $LOCAL_FILES/update
  if [[ -f "/etc/ultimate-updater/temp/exec_host" && "$HOSTNAME" != "$EXEC_HOST" ]]; then rm -rf $LOCAL_FILES; fi
}
set -e
trap EXIT EXIT

# Check Cluster Mode
if [[ -f "/etc/corosync/corosync.conf" ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster "
else
  MODE="  Host  "
fi

# Run
NAME_CHANGING
export TERM=xterm-256color
if ! [[ -d "/etc/ultimate-updater/temp" ]]; then mkdir /etc/ultimate-updater/temp; fi
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
    echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$IP| ($HOSTNAME)${CL}\n"
    if [[ "$WITH_HOST" == true ]]; then
      UPDATE_HOST_ITSELF
    else
      echo -e "${BL}[Info] Skipped host itself by the user${CL}\n\n"
    fi
    if [[ "$WITH_LXC" == true ]]; then
      CONTAINER_UPDATE_START
    else
      echo -e "${BL}[Info] Skipped all containers by the user${CL}\n"
    fi
    if [[ "$WITH_VM" == true ]]; then
      VM_UPDATE_START
    else
      echo -e "${BL}[Info] Skipped all VMs by the user${CL}\n"
    fi
  fi
fi

exit 0
