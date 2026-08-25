# Scheduler

The Scheduler page can create daily or weekly schedules for:

- Check all systems
- Update all systems

Schedules are stored as data in `/etc/ultimate-updater/schedules.json` and are
executed by native systemd timers. No schedules are created by default.

Scheduled jobs call the existing Ultimate Updater CLI/job runner. Existing
include/exclude filters, safety rules, locks, lifecycle handling, notifications,
status capture, and reboot policy therefore remain authoritative. `Run now`
uses the same job entry point.

Times use the local system timezone shown in the WebUI. Schedules can be
enabled, disabled, edited, or deleted without changing `update.conf`.
