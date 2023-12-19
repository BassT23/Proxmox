#!/bin/bash

##################
# Welcome-Screen #
##################

VERSION="1.3.5"

# Branch
BRANCH="develop"

# Variable / Function
CONFIG_FILE="/root/Ultimative-Updater/update.conf"
CHECK_OUTPUT=$(stat -c%s /root/Ultimative-Updater/check-output)
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"

# Colors
# BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Version Check
VERSION_CHECK () {
  curl -s $SERVER_URL/update.sh > /root/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update.sh)
  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /usr/local/bin/update)
  if [[ "$BRANCH" == beta ]]; then
    echo -e "${OR}*** Ultimative-Updater is on beta branch ***${CL}"
  elif [[ "$BRANCH" == develop ]]; then
    echo -e "${OR}*** Ultimative-Updater is on develop branch ***${CL}"
  fi
  if [[ "$SERVER_VERSION" > "$LOCAL_VERSION" ]]; then
    echo -e "${OR}    *** A newer version is available ***${CL}\n\
      Installed: $LOCAL_VERSION / Server: $SERVER_VERSION\n\
      ${OR}You can update with <update -up>${CL}\n"
    VERSION_NOT_SHOW=true
  elif  [[ ! -s /root/update.sh ]]; then
    echo -e "${OR} *** You are offline - can't check version ***${CL}"
  elif [[ "$BRANCH" == master ]]; then
      echo -e "${GN}       Ultimative-Updater is UpToDate${CL}"
  fi
  if [[ "$VERSION_NOT_SHOW" != true ]]; then echo -e "              Version: $LOCAL_VERSION\n"; fi
  rm -rf /root/update.sh
}

READ_WRITE_CONFIG () {
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' $CONFIG_FILE)
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' $CONFIG_FILE)
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' $CONFIG_FILE)
  RUNNING=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' $CONFIG_FILE)
  STOPPED=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' $CONFIG_FILE)
#  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' $CONFIG_FILE)
#  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' $CONFIG_FILE)
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' $CONFIG_FILE)
  if [[ $ONLY != "" ]]; then
    echo -e "${OR}Only is set. Not all machines are checked.${CL}\n"
  elif [[ $ONLY == "" && $EXCLUDED != "" ]]; then
    echo -e "${OR}Exclude is set. Not all machines are checked.${CL}\n"
  elif [[ $WITH_HOST != true || $WITH_LXC != true || $WITH_VM != true ||$RUNNING != true || $STOPPED != true ]]; then
    echo -e "${OR}Variable is set in config file. Some machines will not be checked!${CL}\n"
  fi
}

TIME_CALCULTION () {
MOD=$(date -r "/root/Ultimative-Updater/check-output" +%s)
NOW=$(date +%s)
DAYS=$(( (NOW - MOD) / 86400 ))
HOURS=$(( (NOW - MOD) / 3600 ))
MINUTES=$(( (NOW - MOD) / 60 ))
}

# Welcome
if [[ -f /etc/motd ]]; then
  echo
  neofetch
fi
VERSION_CHECK
READ_WRITE_CONFIG
if [[ -f /root/Ultimative-Updater/check-output ]]; then
  TIME_CALCULTION
  if [[ $DAYS -gt 0 ]]; then
    echo -e "     Last Update Check: $DAYS day(s) ago\n"
  elif [[ $HOURS -gt 0 ]]; then
    echo -e "     Last Update Check: $HOURS hour(s) ago\n"
  else
    echo -e "     Last Update Check: $MINUTES minute(s) ago\n"
  fi
  if [[ -f /root/Ultimative-Updater/check-output ]] && [[ $CHECK_OUTPUT -gt 0 ]]; then
    echo -e "${OR}Available Updates:${CL}"
    echo -e "S = Security / N = Normal"
    cat /root/Ultimative-Updater/check-output
  fi
  echo
fi

exit 0
