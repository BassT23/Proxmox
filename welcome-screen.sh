#!/bin/bash

##################
# Welcome-Screen #
##################

# shellcheck disable=SC2034

VERSION="1.9"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
CHECK_OUTPUT=$(stat -c%s $LOCAL_FILES/check-output)
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"

# Colors
OR="\e[1;33m"
GN="\e[1;92m"
CL="\e[0m"

# Version Check
VERSION_CHECK () {
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/update.sh > /root/update_master.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/beta/update.sh > /root/update_beta.sh
  curl -s https://raw.githubusercontent.com/BassT23/Proxmox/develop/update.sh > /root/update_develop.sh
  MASTER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update_master.sh)
  BETA_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update_beta.sh)
  DEVELOP_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update_develop.sh)
  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' $LOCAL_FILES/update.sh)
  if [[ "$BRANCH" == develop ]]; then
    if  [[ ! -s /root/update_develop.sh ]]; then
      echo -e "${OR}*** You are offline - can't check version ***${CL}\n"
      echo -e "${OR}*** The Ultimate Updater is on develop branch ***${CL}"
    elif [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Master: $MASTER_VERSION\n\
        ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$BETA_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Beta: $BETA_VERSION\n\
         ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$DEVELOP_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
     Installed: $LOCAL_VERSION / Github-Develop: $DEVELOP_VERSION\n\
        ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    else
      echo -e "${GN}       The Ultimate Updater is UpToDate${CL}"
    fi
  fi
  if [[ "$BRANCH" == beta ]]; then
    if  [[ ! -s /root/update_beta.sh ]]; then
      echo -e "${OR}*** You are offline - can't check version ***${CL}\n"
      echo -e "${OR}*** The Ultimate Updater is on beta branch ***${CL}"
    elif [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Master: $MASTER_VERSION\n\
        ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$BETA_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
       Installed: $LOCAL_VERSION / Github-Beta: $BETA_VERSION\n\
         ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    elif [[ "$LOCAL_VERSION" < "$DEVELOP_VERSION" ]]; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
     Installed: $LOCAL_VERSION / Github-Develop: $DEVELOP_VERSION\n\
        ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    else
      echo -e "${GN}       The Ultimate Updater is UpToDate${CL}"
    fi
  fi
  if [[ "$BRANCH" == master ]]; then
    if  [[ ! -s /root/update_master.sh ]]; then
      echo -e "${OR}*** You are offline - can't check version ***${CL}\n"
    elif [[ "$LOCAL_VERSION" < "$MASTER_VERSION" ]]; then
      echo -e "${OR}    *** A newer version is available ***${CL}\n\
        Installed: $LOCAL_VERSION / Server: $MASTER_VERSION\n\
        ${OR}You can update with <update -up>${CL}\n"
      VERSION_NOT_SHOW=true
    else
        echo -e "${GN}       The Ultimate Updater is UpToDate${CL}"
    fi
  fi
  if [[ "$VERSION_NOT_SHOW" != true ]]; then echo -e "              Version: $LOCAL_VERSION\n"; fi
  rm -rf /root/update_master.sh
  rm -rf /root/update_beta.sh
  rm -rf /root/update_develop.sh
}

READ_WRITE_CONFIG () {
  WITH_HOST=$(awk -F'"' '/^CHECK_WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  if [[ -f "$LOCAL_FILES/tag-filter.sh" ]]; then
    # shellcheck disable=SC1091
    . "$LOCAL_FILES/tag-filter.sh"
    if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
      apply_only_exclude_tags ONLY EXCLUDED
    fi
  fi
  if [[ $ONLY != "" ]]; then
    echo -e "${OR}Only is set. Not all machines are checked.${CL}\n"
  elif [[ $ONLY == "" && $EXCLUDED != "" ]]; then
    echo -e "${OR}Exclude is set. Not all machines are checked.${CL}\n"
  elif [[ $WITH_HOST != true || $WITH_LXC != true || $WITH_VM != true ||$RUNNING != true || $STOPPED != true ]]; then
    echo -e "${OR}The variable is set in config file. Some machines will not be checked!${CL}\n"
  fi
}

TIME_CALCULTION () {
MOD=$(date -r "$LOCAL_FILES/check-output" +%s)
NOW=$(date +%s)
DAYS=$(( (NOW - MOD) / 86400 ))
HOURS=$(( (NOW - MOD) / 3600 ))
MINUTES=$(( (NOW - MOD) / 60 ))
}

# Welcome
if [[ -f /usr/bin/fastfetch ]]; then
  echo
  fastfetch
else
  echo
fi
VERSION_CHECK
READ_WRITE_CONFIG
if [[ -f $LOCAL_FILES/check-output ]]; then
  TIME_CALCULTION
  if [[ $DAYS -gt 0 ]]; then
    echo -e "     Last Update Check: $DAYS day(s) ago\n"
  elif [[ $HOURS -gt 0 ]]; then
    echo -e "     Last Update Check: $HOURS hour(s) ago\n"
  else
    echo -e "     Last Update Check: $MINUTES minute(s) ago\n"
  fi
  if [[ -f $LOCAL_FILES/check-output ]] && [[ $CHECK_OUTPUT -gt 0 ]]; then
    echo -e "${OR}Available Updates:${CL}"
    echo -e "S = Security / N = Normal"
    cat $LOCAL_FILES/check-output
  fi
  echo
fi

exit 0
