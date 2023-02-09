#!/bin/bash
#https://github.com/BassT23/Proxmox

#bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/install.sh)

#Variable / Function
VERSION=1.1

#Colors
YW='\033[33m'
BL='\033[36m'
RD='\033[01;31m'
CM='\xE2\x9C\x94\033'
GN='\033[1;92m'
CL='\033[m'

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
    read -p "For further updates, you need git installed?\nShould I install this for you? Type [Y/y] for yes - enything else will exit" -n 1 -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      apt-get install git -y
    fi
}

function UNINSTALL(){
    rm /usr/local/bin/update
    rm -r /root/Proxmox-Update-Scripts
}

#Error/Exit
set -e

#Install
CHECK_ROOT
if [[ $UNINSTALL == 1 ]]; then
    UNINSTALL
else
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "\nProxmox-Updater is already installed\n"
      read -p "Should I update for you? Type [Y/y] for yes - enything else will exit" -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        update -u
      fi
    else
      INSTALL
    fi
fi
exit 0
