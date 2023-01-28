[![Github All Releases](https://img.shields.io/github/downloads/BassT23/LXC-Update/total.svg)]()

**Proxmox LXC Update Script**

Features:
- Update all LXC Container on an Proxmox Host / or hole Cluster
- Exit tracking, so you can send additional commands for Finish or Failure 
- Logging

Info can be found with `update -h`

**Installation:**

As root on Proxmox Host Terminal:
```
apt install github
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
