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
- Normal run is "Interactive" / Headless Mode can be run with `update -3`

Info can be found with `update -h`


**Update the script:**
======================
`update -u`


**Installation:**
=================
As root on Proxmox Host Terminal:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/install.sh)
```

ToDo:
=====
- [ ] implement extra updates for specific Containers
- [ ] Fix dpkg --configure -a on interactive mode

Credits:
========
[@Uruk](https://github.com/Uruknara) - for help with the code

Changelog:
==========

**v3.0** (10.02.2023)

- Implement single install url

**v2.8** (09.02.2023)

- Cleanup overall code

**v2.7.1** (06.02.2023)

- small fixes

**v2.7** (31.01.2023)

- add root check
- Cleanup overall code

**v2.6** (30.01.2023)

- Cleanup overall code
- Fix promt of update
- Add updating package that been kept back

**v2.5** (30.01.2023)

- added "Headless Mode" as option with `update -3` otherwise runs in "Interactive Mode"

**v2.4** (29.01.2023)

- Visual and Name changes

**v2.3** (29.01.2023)

- Update script itself with `update -u`
