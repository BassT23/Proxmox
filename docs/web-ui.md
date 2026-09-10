# Web UI

[← Back to README](../README.md)

The Web UI is served by `ultimate-updater-web.service` and listens on port
`8765` by default:

```text
https://<proxmox-node>:8765/
```

It uses the Proxmox-managed certificate when available, accepts TLS 1.2 or
newer, and can use an explicitly configured certificate pair. If automatic
HTTPS has no usable certificate, the documented transition fallback is HTTP;
set `WEB_UI_HTTPS=true` when HTTPS must be required. Use the trusted
management network; this is an action-enabled administrator interface.

## Main areas

- **Dashboard:** nodes, LXC/VM guests, external targets, reachability, update
  state, reboot indicators, and warnings.
- **Target details:** OS, transport, normal/security or total-only update
  information, last check, and errors.
- **Jobs and logs:** persistent server-side job state and retained output.
- **Settings:** typed controls for checks, filters, lifecycle, snapshots,
  backups, notifications, and DEBUG.
- **Internal SSH Connections:** resolved sources and explicit overrides for
  nodes and VMs.
- **Version information:** installed version, branch, commit, exact tag when
  available, and available version.

### Dashboard

The dashboard combines the system overview, node and guest status, external
targets, and server-side jobs in one view.

![Ultimate Updater dashboard](images/web-ui/dashboard.png)

### Target selection

The Systems view can optionally manage target selection directly. Enable
**Use Ultimate Updater target selection** in Settings to show independent
**Check** and **Update** controls for Nodes, LXC containers, VMs, and External
systems. Each control cycles through **No explicit selection**, **Only**, and
**Exclude**. The first use asks for confirmation because enabling this mode
ignores existing Proxmox Only/Exclude tags; those tags are not changed or
removed. Disabling the mode keeps the saved rules and restores legacy tag
selection.

### Navigation

Use the compact menu button in the header to open the current navigation. It
contains the three available areas: Dashboard, Settings, and Scheduler.

![Web UI navigation menu](images/web-ui/navigation.png)

### Settings

Settings are grouped into connection management, target selection, update
behavior, backup and safety, extra updates, and notifications.

![Web UI settings](images/web-ui/settings.png)

### Jobs and logs

Jobs run server-side and remain available after the browser session ends. The
Jobs view shows the action, target, start time, result, exit code, and a link
to the retained log.

For a running non-interactive job or Check, choose **Live output**. This is a
read-only terminal view: output is streamed while the job runs, and closing
the browser does not stop the server-side job. The complete log remains
available afterwards for viewing or download.

Interactive update jobs can be opened with **Live terminal** when their
transport supports interaction. This is a real terminal view with PTY output,
ANSI/cursor handling, input, and terminal resizing. A browser disconnect does
not end the job; the terminal can be attached again and existing output may be
replayed. After completion the terminal remains open and shows **Job finished**
or **Job failed**. In either case, existing output remains visible and the
complete log can still be viewed or downloaded. Failed jobs disable further
input, while Close remains available.

On small displays the terminal uses a responsive, fullscreen-like layout. The
mobile keybar provides **Esc**, **Tab**, arrow keys, and **Enter**. **Terminal
Font Size** can be adjusted with the font controls and is saved per browser.

![Web UI jobs and logs](images/web-ui/jobs.png)

### Scheduler

The Scheduler uses the existing job runner and safety rules. It supports
enabled schedules, selected weekdays, next and last run information, and the
actions Edit, Run now, Disable, and Delete.

![Web UI scheduler](images/web-ui/scheduler.png)

The UI does not expose a general shell, arbitrary commands, private keys, or
password storage. Configuration writes preserve unrelated settings and are
validated atomically. Updates require browser confirmation.

### Reboot now

In a target's detail view, **Reboot now** is shown only when **Reboot required**
is **Yes** and the target is a supported Node, LXC, or VM. It is not a general
reboot button in the overview. Guest reboots require one confirmation; Node
reboots require an additional safety confirmation because running guests may be
affected. Running or conflicting jobs, offline targets, and unsupported or
restricted targets block the action.

This manual action is separate from `REBOOT_IF_NEEDED`: that setting controls
reboot handling in the Update path, while **Reboot now** is an explicit action
started from target details.

## Authentication and service control

Normal Proxmox installations authenticate the local administrator through PAM.
The service is root-owned because the existing CLI and job runner need local
permissions. Useful service commands are:

```bash
systemctl status ultimate-updater-web
systemctl restart ultimate-updater-web
journalctl -u ultimate-updater-web
```

The interface is responsive on narrow displays. The dashboard can also show
an expanded external-system section when target details are needed.

![Dashboard with expanded external systems](images/web-ui/dashboard-expanded.png)

The optional login welcome screen is separate from the Web UI. It can show
cached update information at login and uses the local check configuration;
the cache is refreshed by the regular update check. It does not wait for a
live GitHub version request during login.

Related: [Configuration](configuration.md), [SSH and VM access](ssh.md),
[Troubleshooting](troubleshooting.md).
