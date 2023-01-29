#!/bin/bash
#apt-get install github -y
#git clone https://github.com/BassT23/LXC-Update
cp ./update /usr/local/bin
chmod 750 /usr/local/bin/update
if [ ! -d "/root/Proxmox-Update-Scripts/exit" ]; then
  mkdir /root/Proxmox-Update-Scripts/
  mkdir /root/Proxmox-Update-Scripts/exit
fi
cp ./exit/*.* /root/Proxmox-Update-Scripts/exit/
chmod +x /root/Proxmox-Update-Scripts/exit/*.*
