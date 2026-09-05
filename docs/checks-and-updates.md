# Checks and updates

[← Back to README](../README.md)

## Check

A check discovers update state and is read-only as far as technically
possible. It must never reboot a VM. Depending on the lifecycle settings, a
stopped or paused guest may be started or resumed temporarily; the original
state is restored after success or failure.

Checks report reachability, operating system, updater, update counts,
reboot-required state, and errors. A failed target remains visible as a
target error; other targets continue according to the configured error
policy.

## Update

An update is a mutating operation. It runs the selected package-manager or
guest update path, applies configured snapshot/backup protection, and reports
whether a reboot is needed. `REBOOT_IF_NEEDED` applies only here. Review the
target and job log before starting an update.

Checks and updates are executed as server-side jobs where the CLI/Web UI
dispatches a job. The job remains observable after the browser or SSH session
disconnects, and per-target locking prevents conflicting operations.

## Output semantics

APT-like paths can report separate security and normal counts. A total-only
updater reports `Updates: X`; it does not pretend that the total is normal
updates or display an unsupported security split. `Unknown` means a supported
classification could not be determined for that run.

## CLI examples

```text
ultimate-updater check
ultimate-updater check 101
ultimate-updater update 101
ultimate-updater status
ultimate-updater status --json
```

The legacy `update <ID>` syntax remains supported. Use status and journal
logs to follow a server-side job.

Related: [Configuration](configuration.md), [Cluster operation](cluster.md),
[Troubleshooting](troubleshooting.md).
