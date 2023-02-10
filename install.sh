#!/bin/bash

#bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/install.sh)

#Variable / Function
VERSION=1.3

#Colors
YW='\033[33m'
BL='\033[36m'
RD='\033[01;31m'
CM='\xE2\x9C\x94\033'
GN='\033[1;92m'
CL='\033[m'

#Header
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
      *** Installer Version :  $VERSION  *** \n"
  CHECK_ROOT
}

#Check root
function CHECK_ROOT() {
  if [[ $RICM != "1" && $EUID -ne 0 ]]; then
      echo -e >&2 "${RD}--- Please run this as root ---${CL}";
      exit
  fi
}

while getopts iuh opt 2>/dev/null
do
  case $opt in
    i) INSTALL=1;;
    u) UNINSTALL=1;;
    h) echo -e "\nOptions: \
                \n======== \
                \n-i   Install (Automatic - No need to set) \
                \n-u   Uninstall\n"
       exit;;
    ?) echo -e "Wrong option! (-h for Help)"
       exit
  esac
done

function INSTALL(){
    mkdir -p /root/Proxmox-Update-Scripts/exit
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/update > /usr/local/bin/update
    chmod 750 /usr/local/bin/update
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/error.sh > /root/Proxmox-Update-Scripts/exit/error.sh
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/passed.sh > /root/Proxmox-Update-Scripts/exit/passed.sh
    chmod +x /root/Proxmox-Update-Scripts/exit/*.*
    #Check if git is installed?
    hash git 2>/dev/null || {
        echo -e "\nFor further updates, you need git installed."
        read -p "Should I install this for you? Type [Y/y] for yes - enything else will exit" -n 1 -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          apt-get update && apt-get install git -y
        else
          echo -e "\nBye\n"
          exit
        fi
    }
}

function UNINSTALL(){
    rm /usr/local/bin/update
    rm -r /root/Proxmox-Update-Scripts
    echo -e "\nUpdater uninstalled\n"
}

#Error/Exit
set -e
function EXIT() {
  EXIT_CODE=$?
  # Install Finish
  if [[ $EXIT_CODE = "0" ]]; then
    echo -e "${GN}Finished. Use Updater with 'update'.${CL}\n"
  # Install Error
  else
    echo -e "${RD}Error during install --- Exit Code: $EXIT_CODE${CL}\n"
  fi
}

#Install
HEADER_INFO
if [[ $UNINSTALL == 1 ]]; then
    UNINSTALL
else
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "\nProxmox-Updater is already installed."
      read -p "Should I update for you? Type [Y/y] for yes - enything else will exit" -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        update -u
      else
        echo -e "\nBye\n"
        exit
      fi
    else
      INSTALL
    fi
fi
exit 0
