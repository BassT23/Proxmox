#!/bin/bash

#live
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/master"
#beta
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/beta"
#development
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/development"

# Colors
BL="\e[36m"
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

# Welcome
echo
neofetch
VERSION_CHECK

exit 0
