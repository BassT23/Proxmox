```
   __  __          __      __          __   _  ________
  / / / /___  ____/ /___ _/ /____     / /  | |/ / ____/
 / / / / __ \/ __  / __ `/ __/ _ \   / /   |   / /
/ /_/ / /_/ / /_/ / /_/ / /_/  __/  / /___/   / /___
\____/ .___/\____/\____/\__/\___/  /_____/_/|_\____/
    /_/
```


**Proxmox LXC Update Script**
=============================
[![Github All Releases](https://img.shields.io/github/downloads/BassT23/LXC-Update/total.svg)]()

Features:
- Update all LXC Container on an Proxmox Host / or hole Cluster
- Exit tracking, so you can send additional commands for Finish or Failure 
- Logging

Info can be found with `update -h`

**Installation:**

As root on Proxmox Host Terminal:
```
apt install git
```
```
git clone https://github.com/BassT23/LXC-Update
```
```
cd ./LXC-Update
```
```
./install.sh
```

**ToDo:**

- [x] make it workable for Cluster
- [ ] implement extra updates for specific Containers

**Credits:**

https://forum.proxmox.com/
- Uruk
- sshanee
- amhehu
