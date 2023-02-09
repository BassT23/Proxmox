#!/bin/bash
# https://github.com/BassT23/Proxmox

# bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/develop-install/install_new.sh) install

if [[ $EUID -ne 0 ]]; then
    echo -e >&2 "${BRED}Root privileges are required to perform this operation${REG}";
    exit 1
fi

#hash curl 2>/dev/null || {
#    echo -e >&2 "${BRED}cURL is required but missing from your system${REG}";
#    exit 1;

while getopts iuh opt 2>/dev/null
do
  case $opt in
    i) INSTALL=1;;
    u) UNINSTALL=1;;
    h) echo -e "\nOptions: \
                \n======== \
                \n-i   Install (Automatic - No need to set) \
                \n-u   Uninstall\n"
       exit 1;;
    ?) echo -e "Wrong option! (-h for Help)"
       exit 1
  esac
done

function INSTALL(){
    mkdir -p /root/Proxmox-Update-Scripts/exit
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/update > /usr/local/bin/update
    chmod 750 /usr/local/bin/update
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/error.sh > /root/Proxmox-Update-Scripts/exit/error.sh
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/passed.sh > /root/Proxmox-Update-Scripts/exit/passed.sh
    chmod +x /root/Proxmox-Update-Scripts/exit/*.*
}

function UNINSTALL(){
    rm /usr/local/bin/update
    rm -r /root/Proxmox-Update-Scripts
}

# Error/Exit
set -e
function EXIT() {
  EXIT_CODE=$?
}

if [[ $UNINSTALL == 1 ]]; then
    UNINSTALL
else
    if [ -f "/usr/local/bin/update" ]; then
      echo "Proxmox-Updater is already installed"
    else
      INSTALL
    fi
fi
exit 0
