```
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
```
<div align="center">

>  Proxmox® is a registered trademark of Proxmox Server Solutions GmbH.

>  I am no member of the Proxmox Server Solutions GmbH. This is not an official programm from Proxmox!

>  This is distributed in the hope that it will be useful, but
>  WITHOUT ANY WARRANTY; without even the implied warranty of
>  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
>  See the GNU General Public License for more details.


[![GitHub release](https://img.shields.io/github/release/BassT23/Proxmox.svg)](https://GitHub.com/BassT23/Proxmox/releases/)
[![GitHub stars](https://img.shields.io/github/stars/BassT23/Proxmox.svg)](https://github.com/BassT23/Proxmox/stargazers)

</div>

![Screenshot_20230321_055444](https://user-images.githubusercontent.com/30832786/227305825-08736d68-9938-4a3a-9a6d-dfe0d1720922.png)


# Proxmox-Updater
Features:
- Update Proxmox (the host / all cluster nodes / all included LXCs and VMs)
- Normal run is "Interactive" / Headless Mode can be run with `update -s`
- Logging
- Exit tracking, so you can send additional commands for finish or failure (edit files in `/root/Proxmox-Updater/exit`)
- Config file

Info can be found with `update -h`


## Installation:
! You only need to install on one Host !

In Proxmox GUI Host Shell or as root on proxmox host terminal:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

### Cluster-Mode preparation:
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
For that connect from node, on which you install the Proxmox-Updater to node2 with `ssh pve2 uptime` for example. Then from node2 `ssh pve3 uptime`, and so on.


### If you want to update the VMs also, you have two choices:
1. Use the "light and easy" QEMU option

     more infos here: <https://pve.proxmox.com/wiki/Qemu-guest-agent>

2. Use ssh connection with Key-Based Authentication (a little more work, but nicer output and "extra" support)

     more infos here: <https://github.com/BassT23/Proxmox/blob/development/ssh.md>


## Update the script:
`update -up`

If update run into issue, please remove first with:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) uninstall
```
and install new


## Extra Updates:
If updater detects Installation: (disable, if you wand in `/root/Proxmox-Updater/update.conf`)
- PiHole
- ioBroker
- Pterodactyl
- Octoprint
- Docker Container Images


## Config File:
The config file is stored under `/root/Proxmox-Updater/update.conf`

With this file, you can manage the updater. For example; if you don't want to update PiHole, comment the line out with #, or change `true` to `false`.

- Host / LXC / VM
- Headless Mode
- Extra updates
- "stopped" or "running" LXC/VM
- "only" or "exclude" LXC/VM by ID


## Welcome Screen:
The Welcome Screen is an extra for you. Its optional!

Can be installed or uninstalled with:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) welcome
```

- The Welcome-Screen brings an update-checker with it. It check on 07am and 07pm for updates via crontab. The result will show up in Welcome-Screen (Only if updates are available).
- The update-checker also use the config file!
- To force the check, you can run `/root/Proxmox-Updater/check-updates.sh` in Terminal.
- Need neofetch to be installed (if not installed, script will make it automatically)


## Beta Testing:
If anybody want to help with failure search, please test our beta (if available).
Install beta update with:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/beta/install.sh) update
```

## QA:
Error: `ssh: Could not resolve hostname pve1: No address associated with hostname
lost connection`

Answer: [Cluster-Mode Config](https://github.com/BassT23/Proxmox/blob/beta/README.md#cluster-mode-preparation)


## Support:
[![grafik](https://user-images.githubusercontent.com/30832786/227482640-e7800e89-32a6-44fc-ad3b-43eef5cdc4d4.png)](https://ko-fi.com/basst)

## Credits:
[@Uruk](https://github.com/Uruknara) - for help with the code
