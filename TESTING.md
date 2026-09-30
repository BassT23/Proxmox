# Ultimate Updater test environments

The canonical reusable real-cluster lab is documented in
[`tests/e2e/TEST_LAB.md`](tests/e2e/TEST_LAB.md), with the verified fixture
inventory in [`tests/e2e/test-lab-inventory.json`](tests/e2e/test-lab-inventory.json).
Run [`tests/e2e/test-lab-audit.sh`](tests/e2e/test-lab-audit.sh) on
`Proxmox-Test-1` for a read-only live audit.

## Safety

- The dedicated cluster is `Test-Cluster`: `.101` Test-1, `.102` Test-2 and
  `.103` Test-3.
- Automatic or destructive guest changes are restricted to VMID/CTID 900–999.
- Verify cluster identity and quorum before every mutation.
- Production (`192.168.3.0/24`), PBS, pfSense, Mediacenter, HMC and bridge
  infrastructure are forbidden.
- Keep fixtures stopped unless a test requires them and restore their state.
- CT921 is an intentional failure fixture: **DO NOT REPAIR**.
- CT930 and several older guests are currently `UNKNOWN_DO_NOT_TOUCH` until
  their purpose or connectivity is re-established.

## Current lab facts

The 2026-09-26 audit found 29 stopped 9xx guests across the three-node
cluster. The most important reusable roles are:

| Fixture | Role |
| --- | --- |
| CT910 | Debian APT/check/filter |
| CT914 | Alpine APK |
| CT916 | Arch Pacman |
| CT918 | Fedora DNF |
| CT920 | Test-2 remote-node Debian guest |
| CT921 | intentional failure |
| CT927 | External-only Debian 13 APT |
| CT928 | Test-2 remote Debian APT guest |
| CT930 | Test-3 additional-node guest; SSH currently unverified |
| VM971/978 | Linux QGA; 978 is the healthy SSH/QGA reference |
| VM980 | Rocky 10 / #256 investigation; not a passing reference |
| VM983 | Test-2 Debian VM/QGA |
| CT984 | Rocky/CentOS DNF candidate |

Templates are CT926 and VM972. Community-Scripts fixtures include CT900,
CT913, CT923 and CT924. No guest was deleted during the audit because unique,
stopped and legacy fixtures could not all be classified with sufficient
confidence.

For the complete reset procedure, External-only selection rules, capability
gaps, cleanup policy and addition/removal rules, use TEST_LAB.md.
