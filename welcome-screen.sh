#!/bin/bash

VERSION="1.2"

#live
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/master"
#beta
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/beta"
#development
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/development"

CONFIG_FILE="/root/Proxmox-Updater/update.conf"
CHECK_OUTPUT=$(stat -c%s /root/Proxmox-Updater/check-output)

# Colors
# BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

# Version Check
function VERSION_CHECK {
  curl -s $SERVER_URL/update.sh > /root/update.sh
  SERVER_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /root/update.sh)
  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2}' /usr/local/bin/update)
  if [[ $LOCAL_VERSION != "$SERVER_VERSION" ]]; then
    echo -e "${RD}   *** A newer version of Proxmox-Updater is available ***${CL}\n \
               Installed: $LOCAL_VERSION / Server: $SERVER_VERSION\n \
                  ${OR}Update with <update -up>${CL}\n"
  else
    echo -e "        ${GN}Proxmox-Updater is UpToDate${CL}\n \
              Version: $LOCAL_VERSION\n"
  fi
  rm -rf /root/update.sh
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
  if [[ $ONLY == "" && $EXCLUDED != "" ]]; then
    echo -e "${OR}Exclude is set. Not all machines were checked.${CL}\n"
  elif [[ $ONLY != "" ]]; then
    echo -e "${OR}Only is set. Not all machines were checked.${CL}\n"
  elif [[ $WITH_HOST != true || $WITH_LXC != true || $WITH_VM != true ||$RUNNING != true || $STOPPED != true ]]; then
    echo -e "${OR}Variable is set in config file. One or more machines will not be checked${CL}\n"
  fi
}

# Welcome
echo
neofetch
VERSION_CHECK
READ_WRITE_CONFIG
if [[ -f /root/Proxmox-Updater/check-output ]] && [[ $CHECK_OUTPUT -gt 0 ]]; then
  echo -e "${OR}Available Updates:${CL}"
  echo -e "Security Updates = S / Normal Updates = N"
  cat /root/Proxmox-Updater/check-output
  echo
fi

exit 0
