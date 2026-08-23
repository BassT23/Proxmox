# Supported systems

[← Back to README](../README.md)

Support depends on both the operating system and the selected transport.
Checks and updates must be validated for the target before enabling a
mutating path.

| System/updater | Security split | Notes |
| --- | --- | --- |
| Debian/Ubuntu APT | Supported where detected | Normal and security counts are separate. Kali is handled as Debian-based. |
| Fedora DNF | Total-only unless a separate split is reported | Use the current DNF path and review results. |
| CentOS/RHEL YUM/DNF | Total-only unless a separate split is reported | RPM-like systems are not guessed from unknown metadata. |
| Arch Pacman | Total-only | Counts come from the Pacman path. |
| Alpine APK | Total-only | Counts come from the APK path. |
| FreeBSD/pfSense `pkg` | Total-only | Read-only `pkg version -U -l '<'` check. |
| Windows | Current path is experimental/deferred | Requires working QGA and `guest-exec`; not in the supported Beta baseline. |

## FreeBSD and pfSense

pfSense/FreeBSD can be checked over SSH or, when the QEMU Guest Agent and
guest execution work, through QGA. The check uses the read-only package query
`pkg version -U -l '<'` and reports a total update count. There is no reliable
normal/security split for this updater, so the UI and notifications show
`Updates: X`.

`FREEBSD_UPDATES` controls the writing update path only. A disabled setting
does not disable a read-only check; it blocks the actual FreeBSD/pfSense
update operation.

## VM requirements

QGA VMs need both `qm agent <VMID> ping` and the required `guest-exec`
operations. SSH VMs need reachable key-based access. A reachable agent alone
does not guarantee that package commands can be executed.

## External systems

External Linux support is SSH-based and currently covers APT and DNF-style
helper paths according to the external-system configuration. See
[External systems](external-systems.md) for backup and privilege limits.

LXC distribution upgrades use the existing update path where the guest and
package manager support them. Review the target and keep a recovery path
before requesting a distribution upgrade.

Related: [SSH and VM access](ssh.md), [Checks and updates](checks-and-updates.md).
