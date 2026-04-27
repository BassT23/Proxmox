# Plugins

After system packages are updated on each container or VM, the updater runs any enabled plugins. Plugins handle application-specific update logic that goes beyond package manager updates.

---

## How plugins work

Plugins are shell scripts in `/etc/ultimate-updater/plugins/`. Each plugin is:

1. Copied into the target container or VM.
2. Executed there as a subprocess.

Plugins run in alphabetical order by filename. A plugin failure does not abort the rest of the update run.

Each plugin reads its own toggle from the configuration file and checks whether the relevant application is installed before doing anything. Enabling a plugin when the application is not present is harmless.

---

## Built-in plugins

| Plugin file | Application | Config key |
|---|---|---|
| `docker-compose.sh` | Docker Compose projects | `DOCKER_COMPOSE` |
| `iobroker.sh` | ioBroker | `IOBROKER` |
| `octoprint.sh` | OctoPrint | `OCTOPRINT` |
| `pihole.sh` | Pi-hole | `PIHOLE` |
| `pterodactyl.sh` | Pterodactyl Panel + Wings | `PTERODACTYL` |
| `unifi.sh` | Unifi Network Controller | `UNIFI` |

All plugin toggles default to `true`. Set `EXTRA_GLOBAL="false"` to disable all plugins at once.

---

## Docker plugin details

The Docker plugin pulls updated images and recreates containers for all Docker Compose projects found under `COMPOSE_PATH` (default: `/home`). Both Docker Compose v1 (`docker-compose`) and v2 (`docker compose`) are supported.

### Docker cleanup

The Docker plugin can optionally run a full cleanup after updating images:

```bash
DOCKER_PRUNE="true"
```

**Warning:** This permanently removes ALL unused Docker images, containers, networks, and volumes on the system — including those unrelated to the projects that were just updated. This is a destructive, irreversible operation. Only enable it if you understand and accept that it will delete anything Docker considers unused.

---

## Writing your own plugin

Create a `.sh` file in `/etc/ultimate-updater/plugins/`. The file runs inside the container or VM being updated. Use `CONFIG_FILE` to read settings from the main configuration:

```bash
#!/bin/bash

# Read your toggle from the config file
MY_APP=$(awk -F'"' '/^MY_APP=/ {print $2}' "${CONFIG_FILE:-/etc/ultimate-updater/update.conf}")
[[ "${MY_APP}" == true ]] || exit 0

# Check that your application is actually installed
[[ -f /usr/local/bin/myapp ]] || exit 0

echo "--- Updating My App ---"
myapp update
```

If you want to control the plugin from the configuration file, add a toggle key to `update.conf`:

```bash
MY_APP="true"
```

Plugins run in alphabetical order by filename.

---

## Headless mode

Plugins are skipped by default when the updater runs in headless mode (`-s / --silent`). To run plugins even in headless mode, set:

```bash
IN_HEADLESS_MODE="true"
```
