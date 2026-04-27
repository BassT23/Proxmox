# Troubleshooting

---

## Enable debug output

Add this to `/etc/ultimate-updater/update.conf`:

```bash
DEBUG="true"
```

This enables `set -x`, which prints every command as it runs. Useful for tracking down exactly where a failure occurs.

---

## Check the log files

```bash
# Full run output
cat /var/log/ultimate-updater.log

# Errors only
cat /var/log/ultimate-updater-error.log
```

---

## A VM is not being updated

1. **Check that the QEMU guest agent is installed and running inside the VM:**

   ```bash
   qm guest exec <VMID> -- bash -c "echo ok"
   ```

   If this fails, install the agent inside the VM:

   ```bash
   # Debian/Ubuntu
   apt-get install qemu-guest-agent
   systemctl enable --now qemu-guest-agent
   ```

2. **Or configure SSH access** for richer output and plugin support. See [VM Updates via SSH](VM-Updates-via-SSH).

3. **Windows VMs are not supported** and are always skipped.

---

## A container fails to snapshot

Some storage types do not support snapshots (e.g. directory storage).

Options:

- Enable `BACKUP_LXC_MP="true"` to fall back to a full backup automatically when a snapshot fails.
- Set `SNAPSHOT="false"` and `BACKUP="true"` to always use backups instead of snapshots.
- Use ZFS or LVM-Thin storage, which supports snapshots natively.

---

## An LXC container is not being updated

- Check that the container is not a template: `pct config <VMID> | grep template`
- If it is stopped and not starting, check `STOPPED_CONTAINER` in the config.
- If it is excluded, check the `EXCLUDE` setting.

---

## SSH connection fails to a cluster node

- Verify that the Proxmox host can SSH to the other node without a password:
  ```bash
  ssh root@<node-ip> hostname
  ```
- Proxmox configures SSH keys between cluster nodes by default. If it does not work, copy the key manually:
  ```bash
  ssh-copy-id root@<node-ip>
  ```

---

## A plugin is not running

1. Check `EXTRA_GLOBAL="true"` in `update.conf`.
2. Check that the individual plugin toggle is `true` (e.g. `DOCKER_COMPOSE="true"`).
3. Check that the application is installed in the container or VM — plugins exit silently if the application is not found.
4. Check that the updater is not running in headless mode with `IN_HEADLESS_MODE="false"`.

---

## Email notifications are not arriving

- Verify that the system `mail` command works:
  ```bash
  echo "test" | mail -s "test" root
  ```
- If not, configure a mail transport such as `postfix`, `ssmtp`, or `msmtp`.

---

## The welcome screen shows stale data

Refresh it manually:

```bash
update -check
```

The cron job updates the data twice a day automatically.

---

## Report a bug

Check for existing issues before opening a new one:
https://github.com/BassT23/Proxmox/issues
