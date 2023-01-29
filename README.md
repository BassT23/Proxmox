```
     ____
    / __ \_________  _  ______ ___  ____  _  __
   / /_/ / ___/ __ \| |/_/ __ `__ \/ __ \| |/_/
  / ____/ /  / /_/ />  </ / / / / / /_/ />  <
 /_/   /_/   \____/_/|_/_/ /_/ /_/\____/_/|_|
       __  __          __      __
      / / / /___  ____/ /___ _/ /____
     / / / / __ \/ __  / __ `/ __/ _ \
    / /_/ / /_/ / /_/ / /_/ / /_/  __/
    \____/ .___/\____/\____/\__/\___/
        /_/
```


Proxmox Update Script
=====================

Features:
- Update all LXC Container on an Proxmox Host / or hole Cluster
- Update the Host itself
- Exit tracking, so you can send additional commands for Finish or Failure 
- Logging

Info can be found with `update -h`


**Update the script:**
======================
`update -u`


**Installation:**
=================
As root on Proxmox Host Terminal:
```
apt install git
```
```
git clone https://github.com/BassT23/Proxmox /root/Proxmox-Update
```
```
cd /root/Proxmox-Update
```
```
chmod +x ./install.sh
```
```
./install.sh
```
first run:
```
update
```

ToDo:
=====
- [x] make it workable for Cluster
- [ ] implement extra updates for specific Containers


Changelog:
==========
**v2.3** (29.01.2023)

- Update script itself with `update -u`
