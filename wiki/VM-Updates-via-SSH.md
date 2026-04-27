# VM Updates via SSH

By default, VMs are updated through the QEMU guest agent. The guest agent provides basic update functionality, but it has limitations: output is harder to read and plugins cannot run through the agent.

Configuring SSH access per VM gives you:

- Clear, streaming output from the update process
- Plugin support (Docker, Pi-hole, etc.)
- The same experience as LXC container updates

---

## SSH configuration file

Create a file at `/etc/ultimate-updater/VMs/<VMID>`:

```bash
IP="192.168.1.10"
USER="root"
SSH_VM_PORT="22"
SSH_START_DELAY_TIME="45"
```

**Fields:**

| Field | Description |
|---|---|
| `IP` | IP address of the VM |
| `USER` | SSH user (must have root or sudo access) |
| `SSH_VM_PORT` | SSH port (default: 22) |
| `SSH_START_DELAY_TIME` | Seconds to wait after VM boot before connecting |

An example file is at `/etc/ultimate-updater/VMs/example`.

---

## SSH key authentication

The updater connects non-interactively, so SSH key authentication is required.

**1. Generate an SSH key on the Proxmox host** (skip if one already exists):

```bash
ssh-keygen -t ed25519 -C "proxmox-updater"
```

**2. Copy the public key to the VM:**

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<VM_IP>
```

**3. Test the connection:**

```bash
ssh root@<VM_IP> hostname
```

The connection must work without a password prompt before the updater can use it.

---

## Fallback behavior

If the SSH configuration file exists but the VM is not reachable via SSH, the updater falls back to the QEMU guest agent automatically. A warning is printed and the SSH setup guide URL is shown.

If neither SSH nor a QEMU agent is available, the VM is skipped with a warning.

---

## Windows VMs

Windows VMs are not supported and are always skipped. The updater detects the Windows OS type from the Proxmox VM configuration (`ostype: win*`) and skips those VMs automatically.
