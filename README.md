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


**Proxmox Update Script**
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
chmod +x ./install.sh
```
```
./install.sh
```
first run:
```
update
```

**ToDo:**

- [x] make it workable for Cluster
- [ ] implement extra updates for specific Containers
