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


Proxmox-Updater 
===============

Features:
- Update Proxmox (the Host / all Cluster Nodes / all included LXC's)
- Exit tracking, so you can send additional commands for Finish or Failure
- Logging
- Normal run is "Interactive" / Headless Mode can be run with `update -s`

Info can be found with `update -h`

**Update the script:**
======================
`update -up`

**Installation:**
=================
As root on Proxmox Host Terminal:
``` 
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) install 
```

**Credits:**
========
[@Uruk](https://github.com/Uruknara) - for help with the code
