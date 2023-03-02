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

[![GitHub release](https://img.shields.io/github/release/BassT23/Proxmox.svg)](https://GitHub.com/BassT23/Proxmox/releases/)
[![GitHub stars](https://img.shields.io/github/stars/BassT23/Proxmox.svg)](https://github.com/BassT23/Proxmox/stargazers)

</div>
     
# Proxmox-Updater

Features:
- Update Proxmox (the host / all cluster nodes / all included LXCs and VMs)
- Normal run is "Interactive" / Headless Mode can be run with `update -s`
- Logging
- Exit tracking, so you can send additional commands for finish or failure (edit files in `/root/Proxmox-Updater/exit`)
- Config file

Info can be found with `update -h`


## Installation:

In Proxmox GUI Host Shell or as root on proxmox host terminal:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```
### If you want to update the VMs also, please install and run `qemu-guest-agent` on VM.

check out here: <https://pve.proxmox.com/wiki/Qemu-guest-agent> for more infos.


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
- Docker Container Images (disabled by default - need some fixing)


## Config File:

The config file is stored under `/root/Proxmox-Updater/update.conf`

With this file, you can manage the updater. For example; if you don't want to update PiHole, comment the line out with #, or change `true` to `false`.

- choose LXC / VM / Host (include or exclude)
- choose "stopped" or "running" LXC/VM
- Headless Mode
- choose extra updates
- choose "only" or "exclude" LXC/VM by ID


## Welcome Screen

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

## Credits:

[@Uruk](https://github.com/Uruknara) - for help with the code
