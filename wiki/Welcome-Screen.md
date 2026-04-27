# Welcome Screen

The welcome screen shows pending update information when you SSH into the Proxmox host. It displays which hosts, containers, and VMs have updates available, including whether any are security updates.

---

## Install

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) welcome
```

This also prompts you to install `neofetch` or `screenfetch` if neither is already present.

---

## Remove

Run the same command again to uninstall:

```bash
bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) welcome
```

It detects that the welcome screen is already installed and asks if you want to remove it.

---

## How it works

The welcome screen consists of two parts:

1. **`/etc/update-motd.d/01-welcome-screen`** — displayed on SSH login via the MOTD system.
2. **A cron job** in `/etc/crontab` — runs `update -check` twice a day (07:00 and 19:00) to refresh the data.

The data is cached in `/etc/ultimate-updater/check-output` so that login is fast — the check does not run live at login time.

---

## Update the data manually

```bash
update -check
```

---

## Configuration

The update checker used by the welcome screen has its own set of configuration keys (all in `update.conf`):

| Setting | Default | Description |
|---|---|---|
| `CHECK_WITH_HOST` | `true` | Include host in update check |
| `CHECK_WITH_LXC` | `true` | Include LXC containers |
| `CHECK_WITH_VM` | `true` | Include VMs |
| `CHECK_STOPPED_CONTAINER` | `true` | Check stopped containers |
| `CHECK_RUNNING_CONTAINER` | `true` | Check running containers |
| `CHECK_STOPPED_VM` | `true` | Check stopped VMs |
| `CHECK_PAUSED_VM` | `true` | Check paused VMs |
| `CHECK_RUNNING_VM` | `true` | Check running VMs |
| `ONLY_UPDATE_CHECK` | _(empty)_ | Restrict check to matching IDs/tags |
| `EXCLUDE_UPDATE_CHECK` | _(empty)_ | Skip matching IDs/tags |

---

## Email notifications

The update checker can send email notifications when updates are found:

```bash
EMAIL_USER="you@example.com"
EMAIL_NO_UPDATES="false"      # Only email when updates are available
EMAIL_ONLY_SECURITY="false"   # Only email when security updates are available
```

Email is sent via the system `mail` command. Ensure your system has a mail transport configured (e.g. `postfix`, `ssmtp`, or `msmtp`).
