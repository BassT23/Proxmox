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
is valid. An optional list of calendar days (`1` through `31`) can be selected
as well. When one or more month days are selected, they take precedence over
the weekdays; for example, `1` and `15` runs at the configured time on those
calendar days regardless of their weekday. A month day such as `31` is simply
skipped in months that do not contain that day. With no month days selected,
the existing weekday behavior is unchanged. At least one weekday or month day
is required.

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
