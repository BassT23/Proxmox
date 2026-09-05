# Scheduler

The Scheduler page can create schedules for:

- Check all systems
- Check selected targets
- Update all systems
- Update selected targets

Schedules are stored as versioned data in `/etc/ultimate-updater/schedules.json`
and are executed by native systemd timers. No schedules are created by default.

Each schedule stores an explicit list of weekdays. Selecting all seven days is
shown as `Daily`; any combination such as weekdays, weekends, or Mon/Wed/Fri
is valid. At least one day is required.

Selected schedules use the current inventory and store stable target IDs. The
target table supports search, select-all-visible, clear, and retains selected
targets while filtering. Missing targets are shown explicitly and never cause
a selected schedule to fall back to all systems.

Scheduled jobs call the existing Ultimate Updater CLI/job runner. Existing
include/exclude filters, safety rules, locks, lifecycle handling, notifications,
status capture, and reboot policy therefore remain authoritative. `Run now`
uses the same job entry point.

Times use the local system timezone shown in the WebUI. Schedules can be
enabled, disabled, edited, or deleted without changing `update.conf`.

The selected target set is only the requested scope. Existing include/exclude,
eligibility, backup, lifecycle, lock, notification, and reboot rules remain
authoritative. Scheduler actions call the existing single-target or all-target
CLI/jobrunner paths; the Scheduler does not implement a second update engine.
