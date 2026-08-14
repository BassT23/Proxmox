<div align="center">

<img src="https://github.com/user-attachments/assets/df181f9c-683b-4e9b-9234-80c158c7da98"
       style="max-width: 100%; height: auto; display: block; margin: 0 auto;" />

![Screenshot_20240109_113501](https://github.com/BassT23/Proxmox/assets/30832786/640cefd9-0659-4265-b34a-cb5b9905046b)

[![GitHub release](https://img.shields.io/github/release/BassT23/Proxmox.svg)](https://GitHub.com/BassT23/Proxmox/releases/)
[![GitHub stars](https://img.shields.io/github/stars/BassT23/Proxmox.svg)](https://github.com/BassT23/Proxmox/stargazers)
[![downloads](https://img.shields.io/github/downloads/BassT23/Proxmox/total.svg)](https://github.com/BassT23/Proxmox/releases)
[![Discord](https://img.shields.io/discord/1149671790864506882)](https://discord.gg/nVpUg6BKn8)

Proxmox® is a registered trademark of Proxmox Server Solutions GmbH.

I am no member of the Proxmox Server Solutions GmbH. This is not an official program from Proxmox!

</div>

>  This is distributed in the hope that it will be useful, but
>  WITHOUT ANY WARRANTY; without even the implied warranty of
>  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
>  See the GNU General Public License for more details.

<div align="center">

**IN CASE OF EMERGENCY, I HOPE YOU HAVE BACKUPS FROM YOUR MACHINES!**

**YOU HAVE BEEN WARNED!**

</div>

### What does the script do:
- The script makes system updates with apt/dnf/pacman/apk or yum on all nodes/LXCs and VMs (if VMs prepared for that)
- Make a snapshot before update (if your storage support it - [look here](https://pve.proxmox.com/wiki/Storage)). If not supported, you can choose to make a real backup, but this must be enabled in `update.conf` by user (take long time!)
- After all, the updater makes a little cleaning (like `apt autoremove`) 
- If the script detects "extra" installations, it could update this also. Look in config file, for that.
- NEW: use your own scripts during update if you like. [Look here](https://github.com/BassT23/Proxmox/tree/develop#user-scripts)

### Features:
- Update Proxmox VE (the host / all cluster nodes / all included LXCs and VMs)
- LXC distriburion upgrade (deb12 -> deb13) with `update -dist-upgrade`
- Snapshot / Backup support (for Snapshot, your system must prepared for it)
- Normal run is "Interactive" / Headless Mode can be run with `update -s`
- Logging - location can be change in config file
- Exit tracking, so you can send additional commands for finish or failure (edit files in `/etc/ultimate-updater/exit`)
- [Config file](https://github.com/BassT23/Proxmox/tree/master#config-file)
- [Use TAG/ID/Range](https://github.com/BassT23/Proxmox/tree/develop#new-onlyexclude-handling-in-config-file) for "Only" / "Exclude" LXC/VM
- send email after update/check
- Trim filesystem on ext4 nodes

Info can be found with `update -h`

Changelog: [here](https://github.com/BassT23/Proxmox/blob/master/change.log)

## 
# Installation:
In Proxmox GUI Host Shell or as root on proxmox host terminal:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)
```

# Usage:
 - If you want to run the updater globally for all nodes/lxc/vm only run `update`
 - If you want to update only one specific lxc/vm run `update <ID>`

##
## Cluster-Mode preparation:
**! For Cluster Installation, you only need to install on one Host !**

The nodes need to know each other. For that please edit the `/etc/hosts` file on each node. Otherwise, you can use the GUI. (NODE -> System -> Hosts)

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

   A reachable QEMU Guest Agent alone is not sufficient for the updater. The
   `guest-exec` capability is also required. Verify both commands from the
   Proxmox host:

   ```bash
   qm agent <VMID> ping
   qm guest exec <VMID> -- true
   ```

   If `qm agent <VMID> ping` works but `guest-exec` is disabled or not
   allowed, check the guest distribution's QEMU Guest Agent policy or use the
   SSH alternative below.

2. Use ssh connection with Key-Based Authentication (a little more work, but nicer output and "extra" support)

     more infos here: [SSH Connection](https://github.com/BassT23/Proxmox/blob/master/ssh.md)

### Kali Linux VMs

Kali Linux is supported as a Debian-based guest. The VM still has to be
prepared for one of the supported VM connection methods.

For QEMU Guest Agent updates, enable the agent for the VM in Proxmox and
install and start it inside Kali:

```bash
sudo apt update
sudo apt install qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Then verify from the Proxmox host:

```bash
qm agent <VMID> ping
qm guest exec <VMID> -- true
```

Both commands must work for QEMU-based guest updates. A reachable Guest Agent
is not sufficient if the `guest-exec` capability is disabled. Alternatively,
configure key-based SSH access as described in [SSH Connection](https://github.com/BassT23/Proxmox/blob/master/ssh.md).

Kali is handled by the Ultimate Updater as a Debian-based system and uses
`apt` for update checks and updates.

# Update the script:
`update -up`

If update run into issue, please remove first with:
```
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) uninstall
```
and install new

# Testing / Validation

Development changes are validated on dedicated non-production Proxmox test
environments before being pushed to the development branch. Validation covers
single-node and multi-node/cluster scenarios, multiple Linux distributions in
LXC guests, QEMU VMs through SSH and QEMU Guest Agent paths, running and stopped
guest lifecycles, templates, controlled failure cases, normal/check-only and
script-only paths, backup/snapshot handling, and configuration migration from
older updater versions. Technical test-environment details are documented in
[`TESTING.md`](TESTING.md).

# Config File:
The config file is stored under `/etc/ultimate-updater/update.conf`

The active `update.conf` contains your personal settings and is preserved when
the updater is updated. The current project template is provided separately as
`/etc/ultimate-updater/update.conf.dist`. Compare both files to review new or
changed options:

`diff -u /etc/ultimate-updater/update.conf /etc/ultimate-updater/update.conf.dist`

## Target inventory

Global updater settings remain in `update.conf`. The optional
`/etc/ultimate-updater/targets.conf` is reserved for reachability information
about additional systems, so `update.conf` does not have to grow with every
future target. Existing Proxmox hosts, LXC containers, VMs, and `VMs/<VMID>`
definitions continue to use their current mechanisms.

The inventory uses small INI-style sections. The current external-target
implementation detects the operating system, distribution, package manager,
and update method automatically where possible:

```ini
[raspi]
host=192.168.10.50
transport=ssh
user=basst
```

External Debian, Ubuntu, and Raspberry Pi OS style apt-based systems can be
checked and updated over SSH. The operating system and package manager are
detected from `/etc/os-release`; do not add `os` or `updater` fields to the
inventory. SSH key authentication is required, using either root or a user
with passwordless `sudo`. No Ultimate Updater agent is installed on the
remote system. An absent or empty `targets.conf` leaves the existing Proxmox
workflow unchanged. External targets do not receive Proxmox vzdump backups or
snapshots.

Internally, the current Proxmox paths use small shared transport wrappers for
local, LXC (`pct`), and SSH execution. QEMU Guest Agent execution keeps its
existing readiness and policy handling. This prepares a Target → Transport →
Updater split without changing the existing Proxmox target behavior.

## Machine-readable status

`check-updates.sh` additionally writes `/etc/ultimate-updater/status.json`
after a completed check. The file uses `schema_version: 1` and contains one
record per target that produced a result. It is written atomically, so a
failed generation keeps the previous complete file.

Each target record contains its `id`, `type`, `transport`, `reachable`,
detected `os`, selected `updater`, update count, `reboot_required`,
`last_check`, `check_status`, `last_update`, and `error`. Values that cannot
be determined are `null`, rather than being reported as zero or success.
Possible check states are `ok`, `updates_available`, `offline`,
`unsupported`, `not_checked`, and `error`. The JSON is data-only; presentation
belongs to future CLI, notification, or web interfaces.

## Unified CLI

The `ultimate-updater` command is a small frontend for the existing update and
check scripts:

```text
ultimate-updater list
ultimate-updater check [TARGET]
ultimate-updater update TARGET
ultimate-updater status
ultimate-updater status --json
```

`status --json` prints the same `/etc/ultimate-updater/status.json` data used by
the read-only web preview. Existing direct calls to `update.sh` and
`check-updates.sh` remain supported and remain synchronous. The
`ultimate-updater update TARGET` command starts a transient systemd job instead. The
command returns after the job is accepted, so the client session may disconnect.
Use `ultimate-updater status` and `journalctl -u <unit>` to inspect the result
and logs. Direct calls to `update.sh` remain synchronous. A job interrupted by
reboot or shutdown is reported as `interrupted` rather than as a successful
update. Job state is kept in `/var/lib/ultimate-updater/jobs`; `status --json`
continues to expose the existing check-status schema while the human-readable
`status` command includes recorded update jobs.

For an external apt-based target, use the same commands:

```text
ultimate-updater check raspi
ultimate-updater update raspi
```

The update is handed to the node-local session-independent job runner. The
remote system only needs SSH and apt; it does not need an updater agent. A
remote update does not create a Proxmox backup or snapshot, and it is not
automatically rebooted when `/var/run/reboot-required` is present.

## Read-only web preview

A small browser preview is included at `web-ui/server.py`. It uses only the
Python 3 standard library and reads the generated `status.json`; it does not
run package managers, contact targets, or start update jobs. Start it locally
with:

```bash
python3 web-ui/server.py
```

By default it binds to `127.0.0.1:8765` and serves a compact, responsive
overview with a simple target detail view. Use `--bind` and `--port` only when
you intentionally want another local/LAN binding, and use `--status-file` for
a different read-only status source. Missing or invalid status data is shown
as a clear message. The first preview has no check, update, reboot, backup, or
configuration actions; those belong to later roadmap work.

With this file, you can manage the updater. For example; if you don't want to update PiHole, comment the line out with #, or change `true` to `false`.

- Host / LXC / VM
- Headless Mode
- Extra updates
- "stopped" or "running" LXC/VM
- "only" or "exclude" LXC/VM - see below
- Full backup storage: set `BACKUP_STORAGE="<storage-id>"` to select a specific active backup storage. Find valid IDs with `pvesm status -content backup`; for example, `BACKUP_STORAGE="pbs"`. This is the Proxmox storage ID, not a filesystem path or the PBS datastore name. If the storage ID is `pbs` and its datastore is `backups`, use `BACKUP_STORAGE="pbs"`. Leave it empty for the existing automatic selection. An invalid or inactive storage is rejected.

# New Only/Exclude handling in config file:
Expands ONLY/EXCLUDE into a space-separated list of numeric VMIDs.
Supports:
  - Plain VMIDs: 101 202
  - Delimiters: commas / semicolons / pipes / spaces intermixed (e.g. 101,202;203|204)
  - Ranges: 120-125 (inclusive)
  - Mixed IDs + ranges + tags: 110 testing 111 200-202
  - Uppercase user tag input (config tags assumed already lowercase)
    Tag tokens are any token not matching ^[0-9]+$ or ^[0-9]+-[0-9]+$.
  - OR matching across tag tokens.

Behavior summary:
  1. Tokenize ONLY if set/matched; else tokenized EXCLUDE.
  2. For each token:
       number        -> add as VMID
       range a-b     -> expand (a..b)
       tag           -> collect tag for later resolution
  3. Resolve tags to IDs (any tag match) and append, de-duplicating while
     preserving first-seen order (input order then discovery order for tags).
  4. Assign final space-separated list back to ONLY / EXCLUDE variable.
  5. If ONLY provided, EXCLUDE is ignored.

Usage examples:
 - ONLY="backup,windows"
 - ONLY="101,102,105-107"
 - ONLY="110 testtag 111 120-121"
 - ONLY="" EXCLUDE="old 300-302"

# Extra Updates:
If updater detects installation: (disable, if you want in `/etc/ultimate-updater/update.conf`)
- PiHole
- ioBroker
- Pterodactyl
- Octoprint
- Docker Compose (v1 and v2)

# User scripts:
How to use user scripts:

In "/etc/ultimate-updater/scripts.d" create an folder for each LXC/VM who should use it like this:
(000 is the example ID)

/etc/ultimate-updater/scripts.d/000/

here you can put in any script you like, which will be run during update also.
!!! DON'T use free spaces in file name !!! ("file 1.sh" -> "file-1.sh")

these files are used in the "extra update" section at the end of the LXC/VM

To skip the built-in OS update for one guest and run only its own scripts,
create an empty `.script-only` marker in the guest directory:

`/etc/ultimate-updater/scripts.d/<VMID>/.script-only`

Snapshots/backups and the normal guest start/stop lifecycle still apply. The
guest's user scripts are run instead of apt, dnf, yum, pacman or apk.

# Welcome Screen:
The Welcome Screen is an extra for you. It's optional!

- The Welcome-Screen brings an update-checker with it. It check on 07am and 07pm for updates via crontab. The result will show up in Welcome-Screen (Only if updates are available).
- The login screen reads cached version information and does not wait for GitHub. The cache is refreshed by the regular update check.
- The update-checker also uses the config file!
- To force the check, you can run `/etc/ultimate-updater/check-updates.sh` in Terminal.
- You can choose, if screenfetch will be show also (if screenfetch is not installed, script will make it automatically)

# Development Testing:
If anybody wants to help with failure search, please test our `develop` branch.

Install the develop update with `update develop -up`
To go back to master, choose `update -up`

The active update branches are `master` and `develop`. The former beta branch is
no longer an active update channel; `beta-outdated` is retained only as a
historical archive.

# Q&A:
[Discussion](https://github.com/BassT23/Proxmox/discussions/60)

# Support:
[![grafik](https://user-images.githubusercontent.com/30832786/227482640-e7800e89-32a6-44fc-ad3b-43eef5cdc4d4.png)](https://ko-fi.com/basst)

# Contributors:
<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.28%"><a href="=https://github.com/BassT23"><img src="https://avatars.githubusercontent.com/u/30832786?v=4?s=100" width="100px;" alt="BassT23"/><br /><sub><b>BassT23</b></sub></a><br /><a href="https://github.com/BassT23/Proxmox/commits?author=BassT23" title="Code">💻</a> <a href="#maintenance-BassT23" title="Maintenance">🚧</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/Gauvino"><img src="https://avatars.githubusercontent.com/u/68083474?v=4?s=100" width="100px;" alt="Gauvino"/><br /><sub><b>Gauvino</b></sub></a><br /><a href="https://github.com/BassT23/Proxmox/commits?author=Gauvino" title="Code">💻</a> <a href="#translation-Gauvino" title="Documentation">📖</a></td>
      <td align="center" valign="top" width="14.28%"><a href="https://github.com/elbim"><img src="https://avatars.githubusercontent.com/u/28606318?v=4?s=100" width="100px;" alt="elbim"/><br /><sub><b>elbim</b></sub></a><br /><a href="https://github.com/BassT23/Proxmox/commits?author=elbim" title="Code">💻</a> <a href="#translation-elbim"</a></td>
    </tr>
  </tbody>
</table>

<div align="center">

**AI-assisted development:** OpenAI ChatGPT & Codex
Used for code review, debugging, test planning, documentation and release preparation. Changes are reviewed and validated before being included in a release.

</div>
