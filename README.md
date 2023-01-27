**Proxmox LXC Update Script**

Features:
- Update all LXC Container on an Proxmox Host / or hole Cluster
- Exit tracking, so you can send additional commands for Finish or Failure 
- Logging

Info can found with "update -h"

**Installation:**

As root on Proxmox Host Terminal:
```
apt install github
```
```
git clone https://github.com/BassT23/LXC-Update
```
```
cp ./LXC-Update/update /usr/local/bin
```
```
update
```

**ToDo:**

- [x] make it workable for Cluster (v2.0.0)
- [ ] implement extra updates for specific Containers

**Credits:**

https://forum.proxmox.com/
- Uruk
- sshanee
- amhehu
