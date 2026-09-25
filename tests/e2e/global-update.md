# Real global-update E2E lab

This document describes the disposable lab used to validate the complete
controller → remote node/guest → External SSH → `update-all` lifecycle. A
green synthetic test suite is not sufficient evidence for a global update
change; run this lab when global, remote-result, External, status-model, or
notification code changes.

## Topology and safety

Use only a positively identified, disposable Proxmox test cluster. The lab
used during the #350 investigation was:

- controller: `Proxmox-Test-1`
- remote node: `Proxmox-Test-2`
- remote guest: dedicated Debian 9xx LXC
- External fixture: a separate Debian 9xx guest reached through External SSH

The External fixture must be excluded from ordinary PVE guest selection and
selected only through its External target ID. Never use production hosts,
guests, External targets, HMC, or bridge infrastructure. Do not commit keys,
passwords, IP-specific credentials, or generated configuration.

Before mutation, verify cluster name, quorum, node membership, guest ownership,
and that every selected target is disposable and in the authorized 9xx range.
Capture and restore the controller configuration and status model. Do not run
this procedure concurrently with another updater job.

## Deterministic package fixture

Build a harmless package named `ultimate-updater-e2e-fixture` with versions
`1.0` and `1.1`. It should install only a version marker below
`/usr/share/ultimate-updater-e2e/`. Serve both versions from a fixture-local
APT repository. Prepare the remote guest and External fixture with 1.0
installed and 1.1 as the candidate. No maintainer script should start or stop
services, require a reboot, or modify shared data.

Reset each fixture with the normal disposable-fixture procedure, for example
installing the 1.0 package, refreshing the local repository metadata, and
confirming exactly one available update. Do not downgrade core packages.

## Selection and run

Configure the External target with a dedicated ID such as `e2e-ext` and ensure
its physical guest VMID/CTID is excluded from ordinary guest update selection.
Use a separate local control target with zero pending updates and, if testing
run scoping, an old historical `last_update` record.

Run a normal `ultimate-updater check` followed by exactly one
`ultimate-updater update-all`. Record the job unit, start/finish timestamps,
global exit code, complete journal, remote refs and state artifacts, status
model checkpoints, and rendered notification. Confirm that the External
package command executes once.

The expected current-run results are:

- remote guest with one pending update: `Successfully updated`;
- External fixture with one pending update: current `success` and visible in
  the update summary;
- control target with zero pending updates: `Up to date` only when it has a
  current-run result;
- historical results from before the global job: never attributed to the
  current run;
- completed remote node/guest results: no false `Result unavailable`;
- exactly one generic `Guests:` section.

Repeat after a fix at least three times from a clean fixture reset. A genuine
target failure must remain failed with its real exit code; a non-zero global
job does not by itself mean remote handback failed.

## Reset and cleanup

After validation, restore the original updater configuration and status model,
remove temporary selection overrides and diagnostics, restore fixture package
state, and verify no package manager lock or stopped updater process remains.
Stop disposable fixtures unless they are intentionally retained as a named,
documented lab resource. Recheck cluster quorum and node health. Remove any
temporary External helper/configuration unless the fixture is explicitly
retained for future E2E validation.

The lab is reusable only when its fixture roles, reset procedure, safety
boundary, and cleanup status are recorded alongside the validation results.
