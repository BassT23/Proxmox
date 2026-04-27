# Cluster Mode

When the updater detects a Corosync configuration at `/etc/corosync/corosync.conf`, it switches to cluster mode automatically.

---

## How it works

1. The updater reads the cluster node IP addresses from `corosync.conf`.
2. For each node, it copies the updater scripts to that node via SSH.
3. It then runs the update on each node remotely and collects the output.

You can run `update` from any node in the cluster — it will update all nodes, including itself.

---

## Requirements

- Standard SSH key access between all cluster nodes (Proxmox sets this up by default).
- No additional configuration needed.

---

## Usage

```bash
# Auto-detected — just run update normally
update

# Explicit cluster mode
update cluster
```

---

## What gets copied to each node

When updating a remote node, the updater copies:

- The main update script
- The configuration file
- Library files (`lib/`)
- Plugin scripts (`plugins/`)
- VM SSH configuration files (`VMs/`)
- The tag filter script

These files are cleaned up from the remote node after the update completes.

---

## Single-node mode

If no `corosync.conf` is found, the updater runs in single-host mode (updates the local host, its containers, and its VMs only).

To force single-host mode explicitly:

```bash
update host
```
