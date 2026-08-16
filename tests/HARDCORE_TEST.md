# Ultimate Updater Hardcore-Test

This is the reusable working specification for the later owner instruction
`Hardcore-Test starten`. It is a developer/test document, not a release
promise. The actual run is **not started by preparing this document**.

## Operating principle

Try to break Ultimate Updater systematically for **4–6 hours**. The minimum
matrix below is not a ceiling: logs, failures, unusual combinations and newly
observed behaviour may create additional tests during the run.

The workflow is:

1. Read this file and re-verify every live fixture and safety boundary.
2. Record Git, CI, deployment, cluster, storage and target baselines.
3. Create a persistent run with `ultimate-updater hardcore-test start`.
4. Execute normal, unusual, contradictory and deliberately faulty cases.
5. Journal every case, fix ordinary bugs minimally on `develop`, deploy and
   targeted-retest, then continue the remaining run.
6. Restore all injected state and run the final regression/cleanup phase.

An all-green result after 60–90 minutes is not a completed Hardcore-Test.

## Non-negotiable safety boundaries

- Automatic or destructive guest modification is restricted to VMID/CTID
  **900–999**.
- Never modify non-9xx guests automatically.
- The Mediacenter is **NO CONTACT** by default: no wake, SSH, check, update,
  helper installation, configuration write or reboot. It requires a separate,
  explicit owner authorization for a different run.
- PBS is production infrastructure. Do not alter PBS jobs, retention or
  datastore state.
- Shared storage is not a test authorization. Check free space before every
  snapshot/backup phase and stop storage-heavy tests at the configured safety
  threshold.
- Never reboot Proxmox-Test-1 and Proxmox-Test-2 simultaneously. Check quorum,
  reboot sequentially, and verify the first node is healthy before touching
  the second. Proxmox-Test-3 may remain the offline fixture.
- Do not patch PVE core/UI, alter cluster membership, firewalls or production
  networking, or use production systems as fixtures.
- Work only on `develop`; no `master` changes, merge, tag, release or version
  bump.
- No automatic Windows tests in this baseline; Windows is deferred.

## Persistent run control

Runtime state is local and not committed:

```text
/var/lib/ultimate-updater/hardcore-tests/<RUN-ID>/
```

The helper provides:

```text
ultimate-updater hardcore-test start [PHASE] [DESCRIPTION]
ultimate-updater hardcore-test status [RUN-ID]
ultimate-updater hardcore-test stop [RUN-ID]
ultimate-updater hardcore-test list
```

Each run contains `state`, `journal.tsv`, and, when requested, `STOP`.
`status` is one of `running`, `stopping`, `completed`, `aborted` or
`critical-abort`. The journal is append-oriented and records:

```text
TIME  TEST_ID  AREA  TARGET  INITIAL_STATE  FAULT_INJECTED  EXPECTED  ACTUAL
RESULT  BUG_ID  FIX_COMMIT  RETEST  CLEANUP
```

The runner checks `STOP` between cases and before every destructive action.
`Hardcore-Test abbrechen` means: stop starting new cases, safely finish or
stop the current action, clean up, finalize the journal and provide an
intermediate report. This is an owner abort, not a test failure. The report
must include elapsed time, started/completed cases, pass/fail counts, bugs,
open work, Master relevance, fixture states, cleanup state, HEAD, CI and the
reason for stopping.

Automatic abort is allowed only for serious cluster damage, production impact,
shared-storage risk, unrecoverable Node1/Node2, or an unsafe repository/
deployment state. Ordinary bugs, failed fixtures, timeouts, UI regressions and
CI failures after a fix are not automatic abort conditions.

## Baseline and fixture inventory

At the beginning of every run, re-discover the inventory; this table is a
candidate map, not a permanent assertion. Record ID, name, node, type, OS,
version, lifecycle, QGA/SSH reachability, snapshot capability, backup
capability and intended purpose.

| Candidate | Intended use | Safety/state note |
| --- | --- | --- |
| CT910 | Debian/APT, running LXC, filters | Re-check lifecycle before use |
| CT911/912 | Debian/APT, stopped/lifecycle/Compose | Restore original state |
| CT917 | CentOS/DNF investigation | Do not repair automatically |
| CT918 | Fedora/DNF | Re-check OS and lifecycle |
| CT920 | remote Node2/cluster target | Re-check Node2 reachability |
| CT921 | intentional failure/error aggregation | **DO NOT REPAIR** |
| CT922/925/927 | Ubuntu/Debian/filter and External APT fixtures | Re-check actual role |
| CT984 | Rocky/DNF External fixture | Re-check helper/user/config |
| VM978 | healthy Ubuntu SSH/QGA reference | Keep stopped when unused |
| VM980 | Rocky/QGA investigation | Do not alter Issue #256 setup casually |
| VM983 | Debian/QGA/remote Node2 | Keep lifecycle reversible |

Current known topology also includes CT914 Alpine, CT916 Arch, CT923/924
community fixtures, CT926/972 templates, CT915/919/971/973/974 VMs and CT930
on offline Node3. Discover all 900–999 guests before use; templates and
non-purpose guests are not automatically suitable for destructive tests.

## Test phases and minimum matrix

Phases may be reordered or expanded when observations justify it.

### Phase 0 — baseline

- Git HEAD, `develop == origin/develop`, working tree, CI and master state.
- Node1/2 identity, PVE/kernel/reboot state, quorum, membership and storage.
- Node3 offline state; no attempt to start it.
- Web service enabled/active, configured port 8765, HTTP 200 and no-store.
- Active inventory, external targets, jobs and status snapshot.
- Preserve hashes/backups of runtime configs; do not alter them for baseline.

### Phase 1 — installer, config, migration and filters

- Fresh/template config merge, update/selfupdate, modified files and custom
  Web port including occupied 8765 and restoration to 8765.
- `update.conf`: comments, unknown keys, quotes, empty values, malformed and
  duplicate settings, migration and no-change save.
- Legacy `VMs/<ID>` migration, duplicate/conflict/invalid/malicious input,
  idempotence and rollback.
- Check and update filters independently: empty, one match, no match,
  exclude-one, exclude-most, ONLY+EXCLUDE, offline included/excluded and
  approximately 95% excluded. ONLY wins over EXCLUDE separately for each run.
- Prove `CHECK ONLY != UPDATE ONLY` and that single-target actions retain their
  defined semantics.

### Phase 2 — host, LXC, VM and lifecycle

- Host check/update dry or real only on permitted 9xx-safe context.
- LXC running/stopped selection, start delay, lifecycle restoration, snapshot,
  backup, mount points, no updates, updates and package/config failures.
- VM running/stopped/paused where supported, QGA healthy/unavailable/timeout,
  SSH fallback where supported, snapshot, lifecycle restoration and timeout.
- Record lifecycle before and after every case; never leave a fixture changed
  without a journaled cleanup result.

### Phase 3 — External APT/DNF and local settings

- CT927/CT984 or freshly verified equivalents only.
- Non-root SSH, dedicated identity, read-only check, local `external.conf`,
  root-owned helper, restricted sudoers and post-check.
- APT and DNF no-update/product-update paths only when naturally appropriate.
- Local settings: `schema_version`, `ONLY_UPDATE_CHECK`,
  `EXCLUDE_UPDATE_CHECK`, `ONLY`, `EXCLUDE`; prove target independence and
  check/update independence.
- Missing/invalid/outdated helper/config, offline target, backup safety and
  one-time override. Never contact Mediacenter.

### Phase 4 — fault injection

Use only the safety classification below. Prefer mocks, temporary test files,
loopback listeners and reversible fixture-local changes.

### Phase 5 — Web, jobs, selfupdate and port

- PAM/auth-first, CSRF, same-origin, session reload/logout, mobile/desktop.
- Check-all, node-check, target-check, update jobs, multiple jobs, reload/new
  tab persistence, logs, running indicator, completion/failure and duplicate
  suppression.
- Custom port, occupied 8765, service restart, selfupdate persistence and
  restore 8765. Never kill an unrelated listener.

### Phase 6 — mixed/global stress

- Continue-on-error with mixed success/failure/offline/timeout.
- Backup gate plus global update selection, filter combinations, remote Node2,
  External and job/status/notification aggregation.
- Add new cases when logs reveal a plausible untested state.

### Phase 7 — cleanup

- Remove injected errors, locks, listeners, temporary configs, temporary
  targets, test sudoers/users and backups where appropriate.
- Restore lifecycle, Web port 8765, service enabled/active, Node1/2 reachability
  and Node3 offline state.
- Verify no ghost targets, broken package manager, damaged storage, stale stop
  state, dirty Git or unsynchronized branch.

### Phase 8 — final regression

Run the relevant automated suites, syntax/ShellCheck, config/inventory/status/
  external regressions, `git diff --check`, CI and final deployment smoke.

## Fault-injection catalog

| Fault | Classification | Guard |
| --- | --- | --- |
| wrong SSH port, missing key, permission denied, timeout | SAFE WITH PRECAUTIONS | temporary fixture target only |
| wrong hostkey / unreachable test IP | SAFE WITH PRECAUTIONS | known_hosts backup; never auto-accept |
| missing/outdated helper, wrong helper mode, missing sudoers | SAFE | CT927/CT984 only; restore |
| invalid helper action / direct sudo command | SAFE | denial tests only |
| APT/DNF lock | SAFE WITH PRECAUTIONS | temporary lock/mock; never delete a real lock |
| interrupted dpkg state / package failure | SAFE WITH PRECAUTIONS | fixture snapshot/backup and recovery plan |
| repository failure/no updates | SAFE | mock or fixture-local repository only |
| QGA unavailable/timeout and recovery | SAFE WITH PRECAUTIONS | reversible VM 9xx only |
| stopped LXC, timeout, snapshot failure simulation | SAFE WITH PRECAUTIONS | CT9xx and storage threshold |
| invalid/inactive backup storage | SAFE WITH PRECAUTIONS | validate before mutation; no PBS changes |
| low-space simulation | SAFE WITH PRECAUTIONS | bounded loopback/mock only; never fill shared disk |
| invalid boolean/number, duplicate/malformed/unknown config | SAFE | temp copy or fixture config |
| corrupt runtime JSON/state | SAFE WITH PRECAUTIONS | backup state and restore |
| occupied 8765/custom port/reload/multiple jobs | SAFE | local Node1 dummy listener only |
| Node3 offline, temporary Node2 unreachable | SAFE WITH PRECAUTIONS | no Node3 start; bounded Node2 test |
| cluster config, PBS jobs/retention, production networking | DO NOT INJECT | prohibited |
| any non-9xx guest modification | DO NOT INJECT | prohibited |
| Mediacenter contact or modification | DO NOT INJECT | separate owner authorization required |

## Config coverage

The baseline `update.conf.dist` currently defines 59 variables. Every variable
must be assigned one of `DIRECT`, `INDIRECT`, `NOT TESTABLE`, `DEPRECATED` or
`NOT RELEVANT` in the run journal. The initial coverage plan is:

| Coverage | Variables |
| --- | --- |
| DIRECT | `EXIT_ON_ERROR`, `WITH_HOST`, `WITH_LXC`, `WITH_VM`, `STOPPED_CONTAINER`, `RUNNING_CONTAINER`, `STOPPED_VM`, `RUNNING_VM`, `REBOOT_IF_NEEDED`, `ONLY`, `EXCLUDE`, `SNAPSHOT`, `KEEP_SNAPSHOTS`, `BACKUP`, `BACKUP_LXC_MP`, `BACKUP_MODE`, `BACKUP_STORAGE`, `CHECK_WITH_HOST`, `CHECK_WITH_LXC`, `CHECK_WITH_VM`, `CHECK_STOPPED_CONTAINER`, `CHECK_RUNNING_CONTAINER`, `CHECK_STOPPED_VM`, `CHECK_PAUSED_VM`, `CHECK_RUNNING_VM`, `ONLY_UPDATE_CHECK`, `EXCLUDE_UPDATE_CHECK`, `LXC_START_DELAY`, `VM_START_DELAY`, `EMAIL_DAILY_CHECK`, `EMAIL_NO_UPDATES`, `EMAIL_ONLY_SECURITY`, `EMAIL_ONLY_ERROR`, `INCLUDE_PHASED_UPDATES`, `INCLUDE_FSTRIM`, `FSTRIM_WITH_MOUNTPOINT`, `FREEBSD_UPDATES`, `PACMAN_ENVIRONMENT`, `INCLUDE_HELPER_SCRIPTS`, `EXTRA_GLOBAL`, `IN_HEADLESS_MODE` |
| INDIRECT | `USED_BRANCH`, `DEBUG`, `LOG_FILE`, `ERROR_LOG_FILE`, `VERSION_CHECK`, `SSH_PORT`, `EXE_FOR_INTERNET_CHECK`, `URL_FOR_INTERNET_CHECK`, `EMAIL_USER`, `EMAIL_SENDER`, `PIHOLE`, `IOBROKER`, `PTERODACTYL`, `OCTOPRINT`, `DOCKER_COMPOSE`, `UNIFI`, `COMPOSE_PATH` |
| NOT TESTABLE / NOT RELEVANT | `VERSION` unless a release-specific behavior is introduced; any variable not consumed by the current selected path is journaled explicitly rather than silently ignored |

The list must be re-derived from the checked-out `update.conf.dist` at run
start. External config coverage is the complete allowlist:
`schema_version`, `ONLY_UPDATE_CHECK`, `EXCLUDE_UPDATE_CHECK`, `ONLY`, and
`EXCLUDE`. Test each key for valid, empty, unknown, duplicate, malformed,
oversized and old-schema handling.

## Bug handling and reporting

For every real bug: document it, classify severity, record `Master 5.0
affected: YES/NO/UNKNOWN`, apply the smallest fix on `develop`, run targeted
tests, commit/push, wait for CI, deploy, retest and continue the remaining
Hardcore-Test. HIGH/CRITICAL or uncertain general-core impact requires
`MASTER 5.0 ALERT` and no automatic backport.

Normal completion report:

```text
Run ID / Duration
Tests executed / PASS / FAIL
Bugs found / fixed / open
MASTER 5.0 alerts / Safety incidents
Production contacted: NO
Cleanup / Final CI / Final HEAD
HARDCORE TEST: PASS | PASS WITH OPEN ISSUES | FAIL
```

Owner stop report must say `HARDCORE TEST: ABORTED BY OWNER` and include all
partial results and remaining cleanup. A cleanup problem is never hidden;
report it as `CLEANUP OPEN` with the affected fixture.
