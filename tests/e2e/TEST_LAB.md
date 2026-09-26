# Ultimate Updater Proxmox test lab

This is the canonical guide for real Ultimate Updater lifecycle testing. It
describes the verified lab on 2026-09-26. A green synthetic suite is not a
replacement for this lab when changing global update, remote handback,
External, status-model, job or notification code.

## Safety boundary

Only these explicitly verified Proxmox nodes are TEST infrastructure:

| Node | Address | Role |
| --- | --- | --- |
| Proxmox-Test-1 | 192.168.10.101 | controller; primary fixture host |
| Proxmox-Test-2 | 192.168.10.102 | remote-node fixture host |
| Proxmox-Test-3 | 192.168.10.103 | quorum/additional-node fixture host |

Cluster name is `Test-Cluster`. VMID/CTID mutation is restricted to 900–999.
Production (`192.168.3.0/24`), PBS, pfSense, Mediacenter, HMC and bridge
infrastructure are never test targets. Test-3 is currently a cluster member
but direct SSH access is unavailable; use the cluster API read-only until that
is repaired.

Before mutation, verify hostname, cluster name, quorum, node membership and
guest ownership. Keep all fixtures stopped unless a case explicitly needs a
running guest. Restore lifecycle state after every case.

## Permanent fixture inventory

The machine-readable source is [`test-lab-inventory.json`](test-lab-inventory.json).
The live inventory has 29 9xx guests. No guest was deleted during the
2026-09-26 audit: several are unique platform, template, failure or QGA
fixtures and their current purpose cannot be proven from a stopped guest
alone.

| ID | Node | Type / OS | Role | Default |
| --- | --- | --- | --- | --- |
| 910 | Test-1 | Debian 12 LXC | APT/check/filter | stopped |
| 914 | Test-1 | Alpine LXC | APK | stopped |
| 916 | Test-1 | Arch LXC | Pacman | stopped |
| 918 | Test-1 | Fedora LXC | DNF | stopped |
| 920 | Test-2 | Debian LXC | remote-node guest | stopped |
| 921 | Test-1 | Ubuntu LXC | intentional failure | stopped; do not repair |
| 927 | Test-1 | Debian 13 LXC | External-only APT | stopped |
| 928 | Test-2 | Debian LXC | remote APT guest | stopped |
| 930 | Test-3 | Debian LXC | additional-node fixture | stopped; SSH unverified |
| 971 | Test-1 | Ubuntu VM | Linux QGA | stopped |
| 978 | Test-1 | Ubuntu VM | healthy SSH/QGA reference | stopped |
| 980 | Test-1 | Rocky 10 VM | #256 QGA investigation | stopped; do not casually repair |
| 983 | Test-2 | Debian 12 VM | remote VM/QGA | stopped |
| 984 | Test-1 | Rocky/CentOS LXC | RPM/DNF candidate | stopped |

Templates 926 and 972 are source material, not update targets. Community
fixtures 900, 913, 923 and 924 are retained for Community-Scripts coverage,
but must not be contacted as part of ordinary updater tests. 915 (FreeBSD),
919 (suspended VM), 973 (incomplete clone configuration) and 974 (generic QEMU
fixture) remain `UNKNOWN_DO_NOT_TOUCH` until their purpose is re-established.

## Deterministic APT fixture

CT927 and CT928 contain the harmless package `ultimate-updater-e2e-fixture`.
The fixture-local repository is `/opt/uu-e2e-repo` and contains versions 1.0
and 1.1. The package writes only a version marker and has no service,
maintainer-side effect or reboot requirement.

Reset a running fixture from its owning Proxmox node:

```sh
pct exec <id> -- dpkg -i /root/ultimate-updater-e2e-fixture_1.0_amd64.deb
pct exec <id> -- apt-get update \
  -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/uu-e2e-fixture.list \
  -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
pct exec <id> -- apt-cache policy ultimate-updater-e2e-fixture
```

The candidate must be 1.1 and exactly one update must be available. After an
update, install 1.0 again to reset. Do not downgrade core packages.

## #350 global E2E scenario

Use Test-1 as controller, Test-2 as remote node, CT928 as remote guest and
CT927 as External target `ext01`. CT927 must be excluded from ordinary PVE
guest selection and selected only through the External SSH path. The package
update must execute exactly once.

The full-refresh reproduction requires an empty internal `check` selection;
otherwise a partial status merge can mask result-preservation defects. Capture
the original updater config and status model before temporarily selecting CT928
and `ext01` for update.

Run one `ultimate-updater check`, then one `ultimate-updater update-all`.
For lifecycle diagnostics use the opt-in gate:

```sh
UU_EXTERNAL_LIFECYCLE_TRACE=true ultimate-updater update-all
```

The run-scoped JSONL trace is stored beside the global job state. It contains
status metadata only and must be removed after collection. Verify External
success, remote guest success, current-run timestamps, one generic `Guests:`
section and no `Result unavailable` for completed remote work.

## Roles, cleanup and gaps

`KEEP_AND_STANDARDIZE` currently applies to CT927 and CT928. They have
descriptions and `uu-test` role tags. Other roles remain diverse on purpose.
Snapshot chains on 911, 912, 915, 919, 920, 971, 973, 974, 983 and 984 are
retained until their owners' test value is reviewed; they may contain recovery
points. Completed historical remote `.ref`/`.state` files are diagnostic
history, not fixtures; clean them only through an explicit archive/retention
decision.

Missing capabilities:

- No verified Windows QGA fixture exists; #312 needs a licensed disposable
  Windows VM, QGA, local test account, update strategy and snapshot reset.
- No verified RPM VM with working QGA/SSH is available; VM980 is an
  investigation fixture, not a passing reference.
- External RPM is not field-verified; CT984 is a candidate only.
- Test-3 direct SSH/QGA reachability is unresolved.
- Reboot-required and authentication-failure cases need dedicated reversible
  fixtures rather than ad-hoc changes to normal guests.
- There is no separate truly unrelated External host; CT927 is physically a
  PVE guest but semantically External-only in updater selection.

## Adding or removing fixtures

Add a fixture only with a single documented role, owner node, baseline, reset
procedure and safety classification. Prefer a new 9xx fixture over
repurposing a unique platform or failure fixture. Before deletion, archive its
config and snapshots, prove that no active test or issue depends on it, and
document the coverage replacement. Never infer mutation permission from an ID
alone.
