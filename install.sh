#!/bin/bash
apt-get install github -y
git clone https://github.com/BassT23/LXC-Update
cp ./LXC-Update/update /usr/local/bin
cp ./LXC-Update/exit ~/Proxmox-Update
