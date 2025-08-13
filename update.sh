#!/bin/bash

##########
# Update #
##########

VERSION="4.4.3"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"
USER_SCRIPTS="/etc/ultimate-updater/scripts.d"
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Tag helper (if installed)
if [[ -f "$LOCAL_FILES/tag-filter.sh" ]]; then
  # shellcheck disable=SC1091
  . "$LOCAL_FILES/tag-filter.sh"
fi

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

# Check root
CHECK_ROOT () {
  if [[ "$RICM" != true && "$EUID" -ne 0 ]]; then
      echo -e "\n${RD} --- Please run this as root ---${CL}\n"
      exit 2
  fi
}

# Check internet status
CHECK_INTERNET () {
  if ! "$CHECK_URL_EXE" -q -c1 "$CHECK_URL" &>/dev/null; then
    echo -e "\n${OR} Internet check fail - Can't update without internet${CL}\n"
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
        MODE=" Single "
        ONLY=$ARGUMENT
        HEADER_INFO
        if [[ $EXIT_ON_ERROR == false ]]; then echo -e "${BL}[Info]${OR} Exit, if error come up, is disabled${CL}\n"; fi
        echo -e "${BL}[Info]${OR} Update only LXC/VM $ARGUMENT - work only on main host!${CL}\n"
        CONTAINER_UPDATE_START
        VM_UPDATE_START
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
          if [[ $EXIT_ON_ERROR == false ]]; then echo -e "${BL}[Info]${OR} Exit, if error come up, is disabled${CL}\n"; fi
        fi
        echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$IP | ($HOSTNAME)${CL}\n"
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
        # shellcheck disable=SC2317
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
        echo -e "\n${RD} ❌ Error: Got an unexpected argument \"$ARGUMENT\"${CL}";
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
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/update.sh > $LOCAL_FILES/temp/update_master.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/beta/update.sh > $LOCAL_FILES/temp/update_beta.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/develop/update.sh > $LOCAL_FILES/temp/update_develop.sh
  MASTER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update_master.sh)
  BETA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update_beta.sh)
  DEVELOP_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/temp/update_develop.sh)
  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/update.sh)
  if [[ "$BRANCH" == develop ]]; then
    echo -e "${OR}*** The Ultimate Updater is on develop branch ***${CL}"
    if [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Master: $MASTER_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$BETA_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Beta: $BETA_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/beta/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$DEVELOP_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Develop: $DEVELOP_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/develop/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    else
      echo -e "${GN}       The Ultimate Updater is UpToDate${CL}"
    fi
  fi
  if [[ "$BRANCH" == beta ]]; then
    echo -e "${OR}*** The Ultimate Updater is on beta branch ***${CL}"
    if [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Master: $MASTER_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$BETA_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Beta: $BETA_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s "$SERVER_URL"/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    else
      echo -e "\n              ${GN}Script is UpToDate${CL}"
    fi
  fi
  if [[ "$BRANCH" == master ]]; then
    if [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}    *** A newer version is available ***${CL}\n\
        Installed: $LOCAL_VERSION / Server: $MASTER_VERSION"
      if [[ "$HEADLESS" != true ]]; then
        echo -e "${OR}Want to update The Ultimate Updater first?${CL}"
        read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
        if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
          bash <(curl -s "$SERVER_URL"/install.sh) update
        fi
        echo
      fi
      VERSION_NOT_SHOW=true
    else
      echo -e "\n              ${GN}Script is UpToDate${CL}"
    fi
  fi
  if [[ "$VERSION_NOT_SHOW" != true ]]; then echo -e "                 Version: $VERSION"; fi
  rm -rf $LOCAL_FILES/temp/update_master.sh
  rm -rf $LOCAL_FILES/temp/update_beta.sh
  rm -rf $LOCAL_FILES/temp/update_develop.sh
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

# Get Server Versions
STATUS () {
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
  ERROR_LOG_FILE=$(awk -F'"' '/^ERROR_LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL=$(awk -F'"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL_EXE=$(awk -F'"' '/^EXE_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  if [[ "$CHECK_URL_EXE" == '' ]]; then CHECK_URL_EXE="ping"; fi
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' "$CONFIG_FILE")
  EXIT_ON_ERROR=$(awk -F'"' '/^EXIT_ON_ERROR=/ {print $2}' "$CONFIG_FILE")
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING_CONTAINER=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED_CONTAINER=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  RUNNING_VM=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$CONFIG_FILE")
  STOPPED_VM=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$CONFIG_FILE")
  FREEBSD_UPDATES=$(awk -F'"' '/^FREEBSD_UPDATES=/ {print $2}' "$CONFIG_FILE")
  SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT=$(awk -F'"' '/^KEEP_SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "$CONFIG_FILE")
  LXC_START_DELAY=$(awk -F'"' '/^LXC_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  VM_START_DELAY=$(awk -F'"' '/^VM_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  EXTRA_GLOBAL=$(awk -F'"' '/^EXTRA_GLOBAL=/ {print $2}' "$CONFIG_FILE")
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_PHASED_UPDATES=$(awk -F'"' '/^INCLUDE_PHASED_UPDATES=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_FSTRIM=$(awk -F'"' '/^INCLUDE_FSTRIM=/ {print $2}' "$CONFIG_FILE")
  FSTRIM_WITH_MOUNTPOINT=$(awk -F'"' '/^FSTRIM_WITH_MOUNTPOINT=/ {print $2}' "$CONFIG_FILE")
  PACMAN_ENVIRONMENT=$(awk -F'"' '/^PACMAN_ENVIRONMENT=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_KERNEL=$(awk -F'"' '/^INCLUDE_KERNEL=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_KERNEL_CLEAN=$(awk -F'"' '/^INCLUDE_KERNEL_CLEAN=/ {print $2}' "$CONFIG_FILE")
  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    apply_only_exclude_tags ONLY EXCLUDED
  fi
}

# Snapshot/Backup
CONTAINER_BACKUP () {
  if [[ "$SNAPSHOT" == true ]] || [[ "$BACKUP" == true ]]; then
    if [[ "$SNAPSHOT" == true ]]; then
      if pct snapshot "$CONTAINER" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "${BL}[Info]${GN} ✅ Snapshot created${CL}"
        echo -e "${BL}[Info]${GN} Delete old snapshots${CL}"
        LIST=$(pct listsnapshot "$CONTAINER" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          pct delsnapshot "$CONTAINER" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "${BL}[Info]${GN} Done${CL}"
      else
        echo -e "${BL}[Info]${RD} ❌ Snapshot is not possible on your storage${CL}"
      fi
    fi
    if [[ "$BACKUP" == true ]]; then
      echo -e "${BL}[Info] Create a backup for LXC (this will take some time - please wait)${CL}"
      vzdump "$CONTAINER" --mode stop --storage "$(pvesm status -content backup | grep -m 1 -v ^Name | cut -d ' ' -f1)" --compress zstd
      echo -e "${BL}[Info]${GN} ✅ Backup created${CL}\n"
    fi
  else
    echo -e "${BL}[Info]${OR} Snapshot and Backup skipped by the user${CL}"
  fi
}
VM_BACKUP () {
  if [[ "$SNAPSHOT" == true ]] || [[ "$BACKUP" == true ]]; then
    if [[ "$SNAPSHOT" == true ]]; then
      if qm snapshot "$VM" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "${BL}[Info]${GN} ✅ Snapshot created${CL}"
        echo -e "${BL}[Info]${GN} Delete old snapshot(s)${CL}"
        LIST=$(qm listsnapshot "$VM" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          qm delsnapshot "$VM" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "${BL}[Info]${GN} Done${CL}"
      else
        echo -e "${BL}[Info]${RD} ❌ Snapshot is not possible on your storage${CL}"
      fi
    fi
    if [[ "$BACKUP" == true ]]; then
      echo -e "${BL}[Info] Create a backup for the VM (this will take some time - please wait)${CL}"
      vzdump "$VM" --mode stop --storage "$(pvesm status -content backup | grep -m 1 -v ^Name | cut -d ' ' -f1)" --compress zstd
      echo -e "${BL}[Info]${GN} ✅ Backup created${CL}"
    fi
  else
    echo -e "${BL}[Info]${OR} Snapshot and/or Backup skipped by the user${CL}"
  fi
}

# Extras / User scripts
USER_SCRIPTS () {
  if [[ -d $USER_SCRIPTS/$CONTAINER ]]; then
    echo -e "\n*** Run user scripts now ***\n"
    USER_SCRIPTS_LS=$(ls $USER_SCRIPTS/"$CONTAINER")
    pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/user-scripts"
    for SCRIPT in $USER_SCRIPTS_LS; do
      pct push "$CONTAINER" -- "$USER_SCRIPTS"/"$CONTAINER"/"$SCRIPT" "$LOCAL_FILES"/user-scripts/"$SCRIPT"
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && \
                                        $LOCAL_FILES/user-scripts/$SCRIPT"
    done
    pct exec "$CONTAINER" -- bash -c "rm -rf $LOCAL_FILES || true"
    echo -e "\n*** User scripts finished ***\n"
  else
    echo -e "\n*** Script now can run user scripts also ***\n\
Infos here: <https://github.com/BassT23/Proxmox/tree/master#user-scripts>\n"
  fi
}
USER_SCRIPTS_VM () {
  if [[ -d $USER_SCRIPTS/$VM ]]; then
    echo -e "\n*** Run user scripts now ***\n"
    USER_SCRIPTS_LS=$(ls "$USER_SCRIPTS"/"$VM")
    ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p $LOCAL_FILES/user-scripts/
    for SCRIPT in $USER_SCRIPTS_LS; do
      scp "$USER_SCRIPTS"/"$CONTAINER"/"$SCRIPT" "$IP":$LOCAL_FILES/user-scripts/"$SCRIPT"
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && \
                $LOCAL_FILES/user-scripts/$SCRIPT"
    done
    ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "rm -rf $LOCAL_FILES || true"
    echo -e "\n*** User scripts finished ***\n"
  else
    echo -e "\n*** Script now can run user scripts also ***\n\
Infos here: <https://github.com/BassT23/Proxmox/tree/master#user-scripts>\n"
  fi
}
EXTRAS () {
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of the user settings ---${CL}\n"
  elif [[ "$HEADLESS" == true && "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR}--- Skip Extra Updates because of Headless Mode or user settings ---${CL}\n"
  else
    echo -e "\n${OR}--- Searching for extra updates ---${CL}"
    if [[ "$SSH_CONNECTION" != true ]]; then
      pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/"
      pct push "$CONTAINER" -- $LOCAL_FILES/update-extras.sh $LOCAL_FILES/update-extras.sh
      pct push "$CONTAINER" -- $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/update-extras.sh && \
                                        $LOCAL_FILES/update-extras.sh && \
                                        rm -rf $LOCAL_FILES || true"
      USER_SCRIPTS
    # Extras in VMS with SSH_CONNECTION
    elif [[ "$USER" != root ]]; then
      echo -e "${RD}--- You need root user for extra updates - maybe in later relaeses possible ---${CL}"
    else
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p $LOCAL_FILES/
      scp $LOCAL_FILES/update-extras.sh "$IP":$LOCAL_FILES/update-extras.sh
      scp $LOCAL_FILES/update.conf "$IP":$LOCAL_FILES/update.conf
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "chmod +x $LOCAL_FILES/update-extras.sh && \
                $LOCAL_FILES/update-extras.sh && \
                rm -rf $LOCAL_FILES || true"
      USER_SCRIPTS_VM
    fi
    echo -e "${GN}---   Finished extra updates    ---${CL}"
    if [[ "$WILL_STOP" != true ]] && [[ "$WELCOME_SCREEN" != true ]]; then
      echo
    elif [[ "$WELCOME_SCREEN" == true ]]; then
      echo
    fi
  fi
}

# Trim Filesystem
TRIM_FILESYSTEM () {
  if [[ "$INCLUDE_FSTRIM" == true ]]; then
    ROOT_FS=$(df -Th "/" | awk 'NR==2 {print $2}')
    if [[ $(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$CONTAINER"'/) {gsub(/%/, "", $7); print $7}') ]]; then
      if [ "$ROOT_FS" = "ext4" ]; then
        echo -e "${OR}--- Trimming filesystem ---${CL}"
        BEFORE_TRIM=$(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$CONTAINER"'/) {gsub(/%/, "", $7); print $7}')
        local "$BEFORE_TRIM"
        echo -e "${RD}Data before trim $BEFORE_TRIM%${CL}"
        pct fstrim "$CONTAINER" --ignore-mountpoints "$FSTRIM_WITH_MOUNTPOINT"
        AFTER_TRIM=$(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$CONTAINER"'/) {gsub(/%/, "", $7); print $7}')
        local "$AFTER_TRIM"
        echo -e "${GN}Data after trim $AFTER_TRIM%${CL}\n"
        sleep 1.5
      fi
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
  START_HOST=$(hostname -i | cut -d ' ' -f1)
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
    if [[ -f $LOCAL_FILES/tag-filter.sh ]]; then
      scp $LOCAL_FILES/tag-filter.sh "$HOST":$LOCAL_FILES/tag-filter.sh
    fi
    # shellcheck disable=SC2086
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-c host"
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
  echo -e "${OR}--- PVE UPDATE ---${CL}" && pveupdate
  if [[ "$HEADLESS" == true ]]; then
    echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}" && \
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
  else
    if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
      echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
      apt-get dist-upgrade -y || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(apt-get dist-upgrade -y 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}" && \
      apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
    fi
  fi
  echo -e "\n${OR}--- APT CLEANING ---${CL}" && \
  apt-get --purge autoremove -y || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(apt-get --purge autoremove -y 2>&1) || ERROR
  if [[ $ERROR_CODE != "" ]]; then return; fi
  echo
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
    ERROR_CODE=""
    if [[ "$ONLY" == "" && "$EXCLUDED" =~ $CONTAINER ]]; then
      echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $CONTAINER ]]; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "${BL}[Info] Skipped LXC $CONTAINER by the user${CL}\n\n"; else continue; fi
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      echo -e "${BL}[Info] ${OR}LXC $CONTAINER is a template - skip update${CL}\n\n"
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" == true ]]; then
        # Start the container
        WILL_STOP="true"
        echo -e "${BL}[Info]${GN} Starting LXC ${BL}$CONTAINER ${CL}"
        pct start "$CONTAINER"
        echo -e "${BL}[Info]${GN} Waiting for LXC ${BL}$CONTAINER${CL}${GN} to start ${CL}"
        sleep "$LXC_START_DELAY"
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
      else
        echo -e "${BL}[Info] Can't find status, please report this issue${CL}\n\n"
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
  OS=$(pct config "$CONTAINER" | awk '/^ostype/' - | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
#  if [[ "$OS" =~ centos ]]; then
#    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
#  else
#    NAME=$(pct exec "$CONTAINER" hostname)
#  fi
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  # Check Internet connection
  if [[ "$OS" != alpine ]]; then
    if ! pct exec "$CONTAINER" -- bash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"; then
      echo -e "${OR} ❌ Internet check fail - skip this container${CL}\n"
      return
    fi
#  elif [[ "$OS" == alpine ]]; then
#    if ! pct exec "$CONTAINER" -- ash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"; then
#      echo -e "${OR} Internet is not reachable - skip the update${CL}\n"
#      return
#    fi
  fi
  # Backup
  echo -e "${BL}[Info]${OR} Start Snapshot and/or Backup${CL}"
  CONTAINER_BACKUP
  echo
  # Run update
  if [[ "$OS" =~ ubuntu ]] || [[ "$OS" =~ debian ]] || [[ "$OS" =~ devuan ]]; then
    echo -e "${OR}--- APT UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "apt-get update -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get update -y" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    # Check APT in Container
    if pct exec "$CONTAINER" -- bash -c "grep -rnw /etc/apt -e unifi >/dev/null 2>&1"; then
      UNIFI="true"
    fi
    # Check END
    if [[ "$HEADLESS" == true || "$UNIFI" == true ]]; then
      echo -e "\n${OR}--- APT UPGRADE HEADLESS ---${CL}"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y" 2>&1) || ERROR
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        pct exec "$CONTAINER" -- bash -c "apt-get dist-upgrade -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get dist-upgrade -y" 2>&1)  || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y" 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
    fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y" 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      pct exec "$CONTAINER" -- bash -c "apt-get autoclean -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get autoclean -y" 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      EXTRAS
      TRIM_FILESYSTEM
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
    echo -e "\n${OR}--- DNF UPGRATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "dnf -y upgrade" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "dnf -y upgrade" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    echo -e "\n${OR}--- DNF CLEANING ---${CL}"
    pct exec "$CONTAINER" -- bash -c "dnf -y autoremove" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "dnf -y autoremove" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ archlinux ]]; then
    echo -e "${OR}--- PACMAN UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "$PACMAN_ENVIRONMENT pacman -Su --noconfirm" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "$PACMAN_ENVIRONMENT pacman -Su --noconfirm" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ alpine ]]; then
    echo -e "${OR}--- APK UPDATE ---${CL}"
    pct exec "$CONTAINER" -- ash -c "apk -U upgrade" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- ash -c "apk -U upgrade" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    if [[ "$WILL_STOP" != true ]]; then echo; fi
    echo
  elif [[ "$OS" =~ centos ]]; then
    echo -e "${OR}--- YUM UPDATE ---${CL}"
    pct exec "$CONTAINER" -- bash -c "yum -y update" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "yum -y update" 2>&1) || ERROR
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  else
    echo -e "${OR}The system could not be idetified.${CL}"
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
    PRE_OS=$(qm config "$VM" | grep ostype || true)
    if [[ "$ONLY" == "" && "$EXCLUDED" =~ $VM ]]; then
      echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
    elif [[ "$ONLY" != "" ]] && ! [[ "$ONLY" =~ $VM ]]; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"; else continue; fi
    elif (qm config "$VM" | grep template >/dev/null 2>&1); then
      echo -e "${BL}[Info] ${OR}VM $VM is a template - skip update${CL}\n\n"
      continue
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
          qm shutdown "$VM" &
          WILL_STOP="false"
          START_WAITING="false"
        else
          echo -e "${BL}[Info] Skipped VM $VM because, QEMU or SSH hasn't initialized${CL}\n\n"
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
        UPDATE_VM "$VM"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" != true ]]; then
        echo -e "${BL}[Info] Skipped VM $VM by the user${CL}\n\n"
      else
        echo -e "${BL}[Info] Can't find status, please report this issue${CL}\n\n"
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
  echo -e "${BL}[Info]${OR} Start Snapshot and/or Backup${CL}"
  VM_BACKUP
  echo
  # Read SSH config file - check how update is possible
  if [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    if [[ -z "$USER" ]]; then USER="root"; fi
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    if [[ -z "$SSH_VM_PORT" ]]; then SSH_VM_PORT="22"; fi
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    if [[ -z "$SSH_START_DELAY_TIME" ]]; then SSH_START_DELAY_TIME="45"; fi
    if [[ "$START_WAITING" == true ]]; then
      echo -e "${BL}[Info]${OR} Wait for bootup${CL}"
      echo -e "${BL}[Info]${OR} Sleep $SSH_START_DELAY_TIME secounds - time could be set in SSH-VM config file${CL}\n"
      sleep "$SSH_START_DELAY_TIME"
    fi
    if ! (ssh -o BatchMode=yes -o ConnectTimeout=5 -q -p "$SSH_VM_PORT" "$USER"@"$IP" exit >/dev/null 2>&1); then
      echo -e "${RD}  ❌ File for ssh connection found, but not correctly set?\n\
  ${OR}Or need more start delay time.\n\
  ${BL}Please check SSH Key-Based Authentication${CL}\n\
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>
  Try to use QEMU insead\n"
      START_WAITING=false
      UPDATE_VM_QEMU
    else
      # Run SSH Update
      SSH_CONNECTION="true"
      KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
      OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" hostnamectl 2>/dev/null | grep System || true)
      if [[ "$KERNEL" =~ FreeBSD ]] && [[ "$FREEBSD_UPDATES" == true ]]; then
        echo -e "${OR}--- PKG UPDATE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg update || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg update 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR}--- PKG UPGRADE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg upgrade -y || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg upgrade -y 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR}--- PKG CLEANING ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg autoremove -y || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pkg autoremove -y 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo
        # UPDATE_CHECK
        return
      elif [[ "$KERNEL" =~ FreeBSD ]]; then
        echo -e "${OR} Free BSD skipped by user${CL}\n"
        return
      elif [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
        # Check Internet connection
        if ! ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$CHECK_URL_EXE" -c1 "$CHECK_URL" &>/dev/null; then
          echo -e "${OR} ❌ Internet check fail - skip this VM${CL}\n"
          return
        fi
        if [[ "$USER" != root ]]; then
          UPDATE_USER="sudo "
        fi
        echo -e "${OR}--- APT UPDATE ---${CL}"
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER"apt-get update -y || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER"apt-get update -y 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR}--- APT UPGRADE ---${CL}"
        if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
          ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get upgrade -y || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get upgrade -y 2>&1) || ERROR
          if [[ $ERROR_CODE != "" ]]; then return; fi
        else
          ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y 2>&1) || ERROR
          if [[ $ERROR_CODE != "" ]]; then return; fi
        fi
        echo -e "\n${OR}--- APT CLEANING ---${CL}"
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get --purge autoremove -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get --purge autoremove -y 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get autoclean -y" || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get autoclean -y 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      elif [[ "$OS" =~ Fedora ]]; then
        echo -e "\n${OR}--- DNF UPGRADE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" dnf -y upgrade || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" dnf -y upgrade 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR}--- DNF CLEANING ---${CL}"
        ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      elif [[ "$OS" =~ Arch ]]; then
        echo -e "${OR}--- PACMAN UPDATE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pacman -Su --noconfirm || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" pacman -Su --noconfirm 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      elif [[ "$OS" =~ Alpine ]]; then
        echo -e "${OR}--- APK UPDATE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" apk -U upgrade || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" apk -U upgrade 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
      elif [[ "$OS" =~ CentOS ]]; then
        echo -e "${OR}--- YUM UPDATE ---${CL}"
        ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" yum -y update || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(ssh -t -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" yum -y update 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      else
        echo -e "${RD}  ❌ The system is not supported.\n  Maybe with later version ;)\n${CL}"
        echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
      fi
      return
#      elif [[ $OS_BASE == win10 ]]; then
#        ssh -q -p "$SSH_PORT" "$USER"@"$IP" wuauclt /detectnow /updatenow
#        Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -AutoReboot # don't work
    fi
  else
    UPDATE_VM_QEMU
  fi
}

# QEMU
UPDATE_VM_QEMU () {
  echo -e "${BL}[Info]${GN} Try to connect via QEMU${CL}"
  if [[ "$START_WAITING" == true ]]; then
    echo -e "${BL}[Info]${OR} Wait for bootup${CL}"
    echo -e "${BL}[Info]${OR} Sleep $VM_START_DELAY secounds - time could be set in config file${CL}\n"
    sleep "$VM_START_DELAY"
  fi
  if qm guest exec "$VM" test >/dev/null 2>&1; then
    echo -e "${OR}  QEMU found. SSH connection is also available - with better output.${CL}\n\
  Please look here: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n"
    # Run Update
    KERNEL=$(qm guest cmd "$VM" get-osinfo | grep kernel-version || true)
    OS=$(qm guest cmd "$VM" get-osinfo | grep name || true)
    if [[ "$KERNEL" =~ FreeBSD ]] && [[ "$FREEBSD_UPDATES" == true ]]; then
      echo -e "${OR}--- PKG UPDATE ---${CL}"
      qm guest exec "$VM" -- tcsh -c "pkg update" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- tcsh -c "pkg update" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR}--- PKG UPGRADE ---${CL}"
      qm guest exec "$VM" -- tcsh -c "pkg upgrade -y" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- tcsh -c "pkg upgrade -y" | tail -n +2 | head -n -1 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR}--- PKG CLEANING ---${CL}"
      qm guest exec "$VM" -- tcsh -c "pkg autoremove -y" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- tcsh -c "pkg autoremove -y" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
      return
    elif [[ "$KERNEL" =~ FreeBSD ]]; then
      echo -e "${OR} Free BSD skipped by user${CL}\n"
      return
    elif [[ "$OS" =~ Ubuntu ]] || [[ "$OS" =~ Debian ]] || [[ "$OS" =~ Devuan ]]; then
      # Check Internet connection
      if ! (qm guest exec "$VM" -- bash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"); then
        echo -e "${OR} ❌ Internet is not reachable - skip the update${CL}\n"
        return
      fi
      echo -e "${OR}--- APT UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get update -y" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "apt-get update -y" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR}--- APT UPGRADE ---${CL}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        qm guest exec "$VM" --timeout 120 -- bash -c "apt-get upgrade -y" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" --timeout 120 -- bash -c "apt-get upgrade -y" | tail -n +2 | head -n -1 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        qm guest exec "$VM" --timeout 120 -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" --timeout 120 -- bash -c "apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" | tail -n +2 | head -n -1 2>&1) || ERROR
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
      echo -e "\n${OR}--- APT CLEANING ---${CL}"
      qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "apt-get --purge autoremove -y" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      qm guest exec "$VM" -- bash -c "apt-get autoclean -y" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$CONTAINER && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "apt-get autoclean -y" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Fedora ]]; then
      echo -e "\n${OR}--- DNF UPGRADE ---${CL}"
      qm guest exec "$VM" -- bash -c "dnf -y upgrade" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "dnf -y upgrade" | tail -n +2 | head -n -1 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR}--- DNF CLEANING ---${CL}"
      qm guest exec "$VM" -- bash -c "dnf -y --purge autoremove" | tail -n +4 | head -n -1 | cut -c 17- || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "dnf -y --purge autoremove" | tail -n +4 | head -n -1 | cut -c 17- 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Arch ]]; then
      echo -e "${OR}--- PACMAN UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "pacman -Su --noconfirm" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "pacman -Su --noconfirm" | tail -n +2 | head -n -1 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Alpine ]]; then
      echo -e "${OR}--- APK UPDATE ---${CL}"
      qm guest exec "$VM" -- ash -c "apk -U upgrade" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- ash -c "apk -U upgrade" | tail -n +2 | head -n -1 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
    elif [[ "$OS" =~ CentOS ]]; then
      echo -e "${OR}--- YUM UPDATE ---${CL}"
      qm guest exec "$VM" -- bash -c "yum -y update" | tail -n +2 | head -n -1 || ERROR_CODE=$? && ID=$VM && ERROR_MSG=$(qm guest exec "$VM" -- bash -c "yum -y update" | tail -n +2 | head -n -1 2>&1) || ERROR
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    else
      echo -e "${RD}  The system is not supported.\n  Maybe with later version ;)\n${CL}"
      echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
  else
    echo -e "${RD}  ❌ SSH or QEMU guest agent is not initialized on VM ${CL}\n\
  ${OR}If you want to update VMs, you must set up it by yourself!${CL}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
  fi
  CVM=""
}

## General ##
READ_CONFIG

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
# shellcheck disable=SC2329
CLEAN_LOGFILE () {
  if [[ "$RICM" != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
        cat "$LOG_FILE" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE" >/dev/null 2>&1
    chmod 640 "$LOG_FILE"
    if [[ -f ./tmp.log ]]; then
      rm -rf ./tmp.log
    fi
  fi
}

# Error handling
ERROR () {
  echo -e "$ID : $NAME" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo -e "Error code:   $ERROR_CODE" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo -e "Error output: $ERROR_MSG\n" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo
}
ERROR_LOGGING () {
  touch "$ERROR_LOG_FILE"
  true > "$ERROR_LOG_FILE"
}
if [[ $EXIT_ON_ERROR == false ]]; then
  ERROR_LOGGING
else
  set -e
fi

# 
# shellcheck disable=SC2329
EXIT () {
  EXIT_CODE=$?
  if [[ -f "/etc/ultimate-updater/temp/exec_host" ]]; then
    EXEC_HOST=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' /etc/ultimate-updater/temp/exec_host)
  else
    echo "no exec host file exist"
  fi
  if [[ "$WELCOME_SCREEN" == true ]]; then
    scp "$LOCAL_FILES"/check-output "$EXEC_HOST":"$LOCAL_FILES"/check-output
  fi
  # Exit without echo
  if [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "$RICM" != true ]]; then
      if [[ -f "$ERROR_LOG_FILE" ]] && [[ -s "$ERROR_LOG_FILE" ]]; then
        echo -e "${OR}❌ Finished, with errors.${CL}\n"
        echo -e "Please checkout $ERROR_LOG_FILE"
        echo
        CLEAN_LOGFILE
      else
        echo -e "${GN}✅ Finished, all updates done.${CL}\n"
        "$LOCAL_FILES/exit/passed.sh"
        CLEAN_LOGFILE
      fi
    fi
  else
  # Update Error
    if [[ "$RICM" != true ]]; then
      echo -e "${RD}❌ Error during update --- Exit Code: $EXIT_CODE${CL}\n"
      "$LOCAL_FILES/exit/error.sh"
      CLEAN_LOGFILE
    fi
  fi
  sleep 3
  rm -rf /etc/ultimate-updater/temp/var
  rm -rf "$LOCAL_FILES"/update
  if [[ -f "/etc/ultimate-updater/temp/exec_host" && "$HOSTNAME" != "$EXEC_HOST" ]]; then rm -rf "$LOCAL_FILES"; fi
}
trap EXIT EXIT

# Check Cluster Mode
if [[ -f "/etc/corosync/corosync.conf" ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster "
else
  MODE="  Host  "
fi

# Run
export TERM=xterm-256color
if ! [[ -d "/etc/ultimate-updater/temp" ]]; then mkdir /etc/ultimate-updater/temp; fi
OUTPUT_TO_FILE
IP=$(hostname -i | cut -d ' ' -f1)
ARGUMENTS "$@"

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true ]]; then
  HEADER_INFO
  if [[ $EXIT_ON_ERROR == false ]]; then echo -e "${BL}[Info]${OR} Exit, if error come up, is disabled${CL}\n"; fi
  if [[ "$MODE" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    echo -e "${BL}[Info]${GN} Updating Host${CL} : ${GN}$IP | ($HOSTNAME)${CL}\n"
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