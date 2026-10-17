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

Scheduled **Update** jobs do not reboot by default. They use
`REBOOT_IF_NEEDED="false"` unless an administrator explicitly enables the
setting. When enabled, only the existing supported guest reboot path may be
requested after a fresh successful update result requires it; originally
stopped guests retain their stopped state. API updates never use this
automatic reboot path, and Proxmox host, external, unsupported, or uncertain
reboots remain manual.

Scheduled **Check** jobs default to the existing read-only `initial-inventory`
lifecycle, preserving the rule that stopped/paused VMs and containers must not
be started or resumed just to collect update availability. Each check schedule
stores `check_lifecycle_mode`: `read_only` (the default, including older
schedules without the field) or an explicitly selected `normal` mode. Normal
mode uses the existing configured `CHECK_STOPPED_*` and paused-VM rules and is
never enabled implicitly. The WebUI asks for confirmation when normal mode is
first selected.

All scheduled checks carry the separate `UU_SCHEDULED_CHECK=true` marker for
notification policy. The lifecycle source and marker are passed through
background systemd check jobs, remote checks, and `Run now` execution. Scheduled
**Update** jobs remain distinct, continue to use `UU_JOB_SOURCE=scheduler`, and
are unaffected by the check lifecycle mode. On upgrade, existing generated
units are reconciled from `schedules.json` without creating, enabling,
disabling, starting, or stopping timers.

Legacy cron check entries are also lifecycle-safe by default and receive the
same read-only context. Custom unrelated cron entries are not changed. No new
scheduler, collector, guest power action, or automatic package update is
introduced.

Times use the local system timezone shown in the WebUI. Schedules can be
enabled, disabled, edited, or deleted without changing `update.conf`.

Scheduled Check notifications are controlled by `EMAIL_DAILY_CHECK`, shown in
Settings as **Email for scheduled checks**. Its default is `true`; setting it
to `false` suppresses mail for scheduled Checks only. Manual global Checks and
Updates are independent of this setting. Single-target notifications use the
separate `EMAIL_SINGLE_RUNS` option.

The selected target set is only the requested scope. Existing include/exclude,
eligibility, backup, lifecycle, lock, notification, and reboot rules remain
authoritative. Scheduler actions call the existing single-target or all-target
CLI/jobrunner paths; the Scheduler does not implement a second update engine.
