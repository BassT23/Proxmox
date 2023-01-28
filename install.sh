#!/bin/bash
#apt-get install github -y
#git clone https://github.com/BassT23/LXC-Update
cp ./update /usr/local/bin
chmod 750 /usr/local/bin/update
if [ -f "~/Proxmox-Update/exit/error.sh" ]; then
  mkdir ~/Proxmox-Update/
  mkdir ~/Proxmox-Update/exit
fi
cp ./exit/*.* ~/Proxmox-Update/exit
