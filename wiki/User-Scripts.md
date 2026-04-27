# User Scripts

User scripts run inside a specific container or VM after all updates and plugins have completed. They are useful for post-update tasks that are specific to a single machine.

---

## Setup

Place your scripts in:

```
/etc/ultimate-updater/scripts.d/<VMID>/
```

Replace `<VMID>` with the numeric ID of the container or VM. For example, scripts for container 101 go in `/etc/ultimate-updater/scripts.d/101/`.

An example script is provided at `/etc/ultimate-updater/scripts.d/000/example.sh`.

---

## How they run

For each container or VM:

1. The updater copies all scripts from `scripts.d/<VMID>/` into the container or VM.
2. Each script is executed there in order.
3. The scripts and any temporary files are removed after execution.

Scripts run as root inside the target container or VM. They have access to the full system environment of that container or VM.

---

## Example script

```bash
#!/bin/bash

# Restart a service after update
systemctl restart myapp
```

---

## Notes

- Scripts must be executable (`chmod +x`).
- Scripts run after plugins.
- A failing script is logged but does not abort the rest of the update run.
- Scripts are cleaned up from the target after execution — the originals in `scripts.d/` are not modified.
