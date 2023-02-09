#!/bin/bash
# https://github.com/BassT23/Proxmox

# bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/develop-install/install_new.sh) install

function install(){
    mkdir -p /root/Proxmox-Update-Scripts/exit
    curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/update > /usr/local/bin/update
    chmod 750 /usr/local/bin/update
    cp ./exit/*.* /root/Proxmox-Update-Scripts/exit/
    chmod +x /root/Proxmox-Update-Scripts/exit/*.*
}

# Error/Exit
set -e
function EXIT() {
  EXIT_CODE=$?
}

if [ -f "/usr/local/bin/update" ]; then
  echo "Proxmox-Updater is already installed"
else
  install
fi

exit 0
