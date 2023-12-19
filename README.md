<div align="center">

Ultimative Updater 
  for Proxmox VE

![Logo](https://github.com/BassT23/Proxmox/assets/30832786/00fa746d-3d65-4b01-8906-50ecb845a50d)

![Screenshot_20230326_130709](https://user-images.githubusercontent.com/30832786/227771669-aae7e7f4-b27e-4095-950a-c6fa1f146503.png)

[![GitHub release](https://img.shields.io/github/release/BassT23/Proxmox.svg)](https://GitHub.com/BassT23/Proxmox/releases/)
[![GitHub stars](https://img.shields.io/github/stars/BassT23/Proxmox.svg)](https://github.com/BassT23/Proxmox/stargazers)
[![downloads](https://img.shields.io/github/downloads/BassT23/Proxmox/total.svg)](https://github.com/BassT23/Proxmox/releases)
[![Discord](https://img.shields.io/discord/1149671790864506882)](https://discord.gg/nVpUg6BKn8)



Proxmox® is a registered trademark of Proxmox Server Solutions GmbH.

I am no member of the Proxmox Server Solutions GmbH. This is not an official programm from Proxmox!

</div>

>  This is distributed in the hope that it will be useful, but
>  WITHOUT ANY WARRANTY; without even the implied warranty of
>  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
>  See the GNU General Public License for more details.

<div align="center">

**IN CASE OF EMERGENCY, I HOPE YOU HAVE BACKUPS FROM YOUR MACHINES!**

**YOU HAVE BEEN WARNED!**

</div>

### Features:
- Update Proxmox VE (the host / all cluster nodes / all included LXCs and VMs)
- Snapshot / Backup support (for Snapshot, your system must prepared for it)
- Normal run is "Interactive" / Headless Mode can be run with `update -s`
- Logging to ``/var/log/update-"$HOSTNAME".log``
- Exit tracking, so you can send additional commands for finish or failure (edit files in `/root/Proxmox-Updater/exit`)
- [Config file](https://github.com/BassT23/Proxmox/tree/master#config-file)

Info can be found with `update -h`

Changelog: [here](https://github.com/BassT23/Proxmox/blob/master/change.log)


### What does the script do:
- The script make system updates with apt/dnf/pacman/apk or yum on all nodes/LXCs and VMs (if VMs prepared for that)
- Make a snapshot befor update (if your storage support it - [look here](https://pve.proxmox.com/wiki/Storage)). If not supported, you can choose to make a real backup, but this must be enabled in `update.conf` by user (take long time!)
- After all, the updater makes an little cleaning (like `apt autoremove`) 
- If the script detects "extra" installations, it could update this also. Look in config file, for that.

## 
# Installation:
In Proxmox GUI Host Shell or as root on proxmox host terminal:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

## Cluster-Mode preparation:
**! For Cluster Installation, you only need to install on one Host !**

The nodes need to know each other. For that please edit the `/etc/hosts` file on each node. Otherwise you can use the GUI (NODE -> System -> Hosts)

Example add:
```
192.168.1.10   pve1
192.168.1.11   pve2
192.168.1.12   pve3
...
```
IP and Name must match with node ip and its hostname.
- IP can be found in node terminal with `hostname -I`
- hostname can be found in node terminal with `hostname`

After that make the fingerprints.
The used sequence can be check, if you run `awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf"` from the host, on which Proxmox-Updater is installed.
So connect from first node (on which you install the Proxmox-Updater) to node2 with `ssh pve2`. Then from node2 `ssh pve3`, and so on.


## If you want to update the VMs also, you have two choices:
1. Use the "light and easy" QEMU option

     more infos here: [QEMU Guest Agent](https://pve.proxmox.com/wiki/Qemu-guest-agent)

2. Use ssh connection with Key-Based Authentication (a little more work, but nicer output and "extra" support)

     more infos here: [SSH Connection](https://github.com/BassT23/Proxmox/blob/master/ssh.md)


# Update the script:
`update -up`

If update run into issue, please remove first with:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) uninstall
```
and install new


# Extra Updates:
If updater detects installation: (disable, if you want in `/root/Proxmox-Updater/update.conf`)
- PiHole
- ioBroker
- Pterodactyl
- Octoprint
- Docker Container Images


# Config File:
The config file is stored under `/root/Proxmox-Updater/update.conf`

With this file, you can manage the updater. For example; if you don't want to update PiHole, comment the line out with #, or change `true` to `false`.

- Host / LXC / VM
- Headless Mode
- Extra updates
- "stopped" or "running" LXC/VM
- "only" or "exclude" LXC/VM by ID


# Welcome Screen:
The Welcome Screen is an extra for you. Its optional!

- The Welcome-Screen brings an update-checker with it. It check on 07am and 07pm for updates via crontab. The result will show up in Welcome-Screen (Only if updates are available).
- The update-checker also use the config file!
- To force the check, you can run `/root/Proxmox-Updater/check-updates.sh` in Terminal.
- You can choose, if neofetch will be show also (if neofetch is not installed, script will make it automatically)


# Beta Testing:
If anybody want to help with failure search, please test our beta (if available).

Install beta update with `update beta -up`

To go back to master, choose `update -up`


# Q&A:
[Discussion](https://github.com/BassT23/Proxmox/discussions/60)


# Support:
[![grafik](https://user-images.githubusercontent.com/30832786/227482640-e7800e89-32a6-44fc-ad3b-43eef5cdc4d4.png)](https://ko-fi.com/basst)

# Credits:
[@Uruk](https://github.com/Uruknara) / [@elbim](https://github.com/elbim)
