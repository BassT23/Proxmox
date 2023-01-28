#!/bin/bash
#apt-get install github -y
#git clone https://github.com/BassT23/LXC-Update
cp ./update /usr/local/bin
chmod 750 /usr/local/bin/update
if [ -f "root/Proxmox-Update/exit/error.sh" ]; then
  mkdir root/Proxmox-Update/
  mkdir root/Proxmox-Update/exit
fi
cp ./exit/*.* root/Proxmox-Update/exit
