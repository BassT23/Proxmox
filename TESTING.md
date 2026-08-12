# Ultimate Updater test environment

This document describes the dedicated test guests. Guests marked `DO NOT
REPAIR` are intentional failure fixtures and must remain in their prepared
state.

## Proxmox test nodes

| Node | Role | Notes |
| --- | --- | --- |
| `updater-test-single` | Single-node tests | PVE 8.4.11, CT 901/902 |
| `updater-test-node1` | Main cluster test node | PVE 9.1.9, cluster `Test-Cluster` |
| `updater-test-node2` | Remote cluster test node | PVE 9.0.5, CT 920 |

The test cluster is quorate with node1 and node2. Node3 is intentionally
reserved for special failure tests and is not required for normal coverage.

## VM and LXC fixtures

| VMID | Name | OS/type | Purpose | State |
| --- | --- | --- | --- | --- |
| 978 | `ultimate-updater-ref` | Ubuntu 22.04.5 VM | Healthy SSH and QEMU Guest Agent reference; SSH/QGA and script-only paths | Keep stopped when unused |
| 980 | `ultimate-updater-rocky10` | Rocky Linux 10 GenericCloud VM | Issue #256 QEMU Guest Agent investigation | Initial boot currently blocked under TCG; keep as dedicated fixture |
| 901/902 | Debian 13/12 LXC | APT, snapshot and backup tests | Normal fixtures | Keep original state |
| 910/911/912/927 | Debian LXC | APT, Compose, snapshot/backup and bind-mount tests | Normal fixtures | Keep original state |
| 914 | Alpine LXC | APK tests | Distribution fixture | Keep original state |
| 916 | Arch LXC | Pacman tests | Distribution fixture | Keep original state |
| 917 | CentOS LXC | YUM/DNF investigation | Special distribution fixture | Do not repair automatically |
| 918 | Fedora LXC | DNF tests | Distribution fixture | Keep original state |
| 921 | `ubuntu-failure` LXC | Intentional failure fixture | Error logging and continuation tests | **DO NOT REPAIR** |
| 922 | Ubuntu LXC | APT, filters and script-only tests | Normal fixture | Keep original state |
| 920 | Debian LXC on node2 | Cluster/remote-node tests | Remote fixture | Keep original state |

## VM 978 reference requirements

VM 978 is the healthy VM reference and must provide:

- test-network address `192.168.10.104`
- SSH access using the dedicated test key
- Proxmox QEMU Guest Agent enabled
- working `qm agent <VMID> ping`, `get-osinfo` and `qm guest exec`
- Ubuntu/Debian package management
- no intentional failure state

The VM runs with `kvm=0` because the test Proxmox nodes are nested. Slow boot
and package operations are expected.

## Rocky Linux 10 fixture

VM 980 uses the official Rocky Linux 10 GenericCloud image and test address
`192.168.10.105`. The image checksum was verified before import. The initial
TCG boot reached the bootloader but did not yet expose QEMU Guest Agent or
network access in the available test window. Do not enable special QGA RPC
allowlists or otherwise alter the guest before documenting a reproduction of
Issue #256.

## Cleanup rules

- Restore guests to their original running/stopped state after each test.
- Remove temporary scripts, markers, snapshots and backups after use.
- Keep VM 978 stopped when not actively testing it.
- Do not start node3 for ordinary tests.
- Never use production nodes or the `192.168.3.x` network for write tests.
