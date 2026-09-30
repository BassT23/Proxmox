# Notifications

[← Back to README](../README.md)

Email notifications use the status produced by checks and updates. Configure
the recipient and sender with `EMAIL_USER` and `EMAIL_SENDER`; the notification
and filtering options include `EMAIL_DAILY_CHECK`, `EMAIL_SINGLE_RUNS`, `EMAIL_NO_UPDATES`,
`EMAIL_ONLY_SECURITY`, and `EMAIL_ONLY_ERROR`.

`EMAIL_SINGLE_RUNS` defaults to false. If enabled, a manually selected
single-target check or update can send one summary containing only that job's
target; global and scheduled summaries are unaffected.
`EMAIL_DAILY_CHECK` defaults to true and controls notifications for scheduled
checks only; the Web UI labels this setting **Email for scheduled checks**.
Manual global runs and update notifications are unaffected.

Notifications distinguish available updates from healthy/no-update,
offline, unsupported, not-checked, and error states. A target error remains
visible even when other targets succeed. Unknown update counts are not added
to the total. Security-only notifications use the security classification
only where the selected updater supports that split.

The same status model feeds CLI, Web UI, and notification output. For
split-capable targets, normal and security counts are shown separately. For
total-only targets such as `pkg`, the message shows `Updates: X` rather than
inventing a normal/security classification.

If mail is not being delivered, first inspect the local updater log and test
the configured mail transport independently. Use `DEBUG=true` temporarily
when additional technical diagnostics are needed; do not leave secrets in
logs or bug reports.

Related: [Configuration](configuration.md), [Troubleshooting](troubleshooting.md).
