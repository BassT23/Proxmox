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

## Optional scheduled success heartbeat

An optional HTTP success heartbeat is available for completed, read-only
scheduled inventory checks. It is disabled by default and is deliberately
file-only; the WebUI does not display or edit its endpoint or token. Create
these files locally when the feature is wanted:

- `/etc/ultimate-updater/scheduled-heartbeat-url` containing one `http://` or
  `https://` endpoint without embedded credentials or a query string;
- `/etc/ultimate-updater/scheduled-heartbeat-token` containing the bearer
  token; and
- `/var/lib/ultimate-updater/scheduled-heartbeat.state` for the last attempted
  run ID.

The URL and token files must be regular, non-symlinked files owned by the
service user (normally `root`) with mode `0600`. Their parent directories must
not be group- or world-writable. Optional absolute-path overrides are
`UU_HEARTBEAT_URL_FILE`, `UU_HEARTBEAT_TOKEN_FILE`, and
`UU_HEARTBEAT_STATE_FILE`; they are propagated through the existing job-runner
environment and are subject to the same validation. Invalid or ambiguous
configuration fails closed and does not send a request. The token is read
from the protected file and is never put in a command-line argument, status
file, API response, WebUI response, log, or diagnostic.

The heartbeat is sent at most once per run, with no redirects, HTTP(S)-only
transport, a 5-second connect timeout, and a 20-second total timeout. A
delivery failure is observable and withholds the heartbeat but does not turn a
successful check into an update or check failure. A corrupt or stale state
file is safely replaced with one bounded run-ID entry; the state contains no
endpoint or token.

Eligibility is intentionally strict: the run must be an authenticated global
scheduled check with `UU_CHECK_JOB_EXECUTION=true`,
`UU_SCHEDULED_CHECK=true`, and `UU_JOB_SOURCE=initial-inventory`; all current
host, LXC, VM, and External records must be reachable, current, successful,
non-skipped, non-warning, non-invalidated, and have valid update counts. A
manual, single-target, update, partial, stale, offline, stopped, paused,
unsupported, warning, or incomplete run never sends a heartbeat. Remote
workers are suppressed by the existing handoff/single-target boundary; the
controller's completed notification path is authoritative, so Apprise and
email do not create duplicate heartbeat events.

This feature is separate from the provider-neutral Apprise transport added in
[Issue #360 / PR #364](https://github.com/BassT23/Proxmox/pull/364). The
heartbeat reuses the completed status and notification decision but does not
add a scheduler, collector, database, guest action, update, snapshot,
backup, or reboot path. The design is an adapted implementation of the
proposal in [Issue #366](https://github.com/BassT23/Proxmox/issues/366) and
[PR #369](https://github.com/BassT23/Proxmox/pull/369) by X1pheR, constrained
to Ultimate Updater's current scheduler, notification, remote-handoff, and
safety boundaries.

The selected target set is only the requested scope. Existing include/exclude,
eligibility, backup, lifecycle, lock, notification, and reboot rules remain
authoritative. Scheduler actions call the existing single-target or all-target
CLI/jobrunner paths; the Scheduler does not implement a second update engine.
