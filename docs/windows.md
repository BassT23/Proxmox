# Windows VMs

[← Back to supported systems](supported-systems.md) · [Checks and updates](checks-and-updates.md)

Windows support uses the Proxmox QEMU Guest Agent (QGA) and the Windows Update
Agent COM API. The tested path does not require an SSH server, WinRM,
PSWindowsUpdate, winget, or an additional Ultimate Updater agent in Windows.

## Validation status

The live test environment validated Windows Server 2025 Standard Evaluation
on VM 986 over the remote cluster path. QGA detection, `guest-exec`,
PowerShell, the built-in Windows Update COM search, update result handling,
and reboot-state detection worked. The direct detached worker installed five
updates in one run (about 1 h 52 min), reported COM result code `2`, and
correctly required a reboot; Windows was then rebooted deliberately and the
post-reboot check completed successfully.

The central product-path check was also validated after the remote payload
was corrected to encode every PowerShell `-EncodedCommand` as UTF-16LE. A
later central product-path update attempt reached VM 986 but stopped in the
read-only servicing preflight after a QGA `guest-exec-status` timeout; it did
not install another update. Therefore the direct Windows update is live
validated, while a complete successful *central product-path installation*
remains pending a stable QGA run. The component store diagnosis previously
reported CBS error `0x800F0983`; `DISM /Online /Cleanup-Image /CheckHealth`
reported no detected corruption.

The detached-job smoke test also confirmed that a guest worker can continue
after the initiating QGA request times out. Its durable state retained the
launcher and worker PIDs through the phase transitions. This is lifecycle
validation only; it is not a successful product-path Windows update
acceptance. A later central check may still fail independently if the
Proxmox/QGA transport times out.

## Requirements

- A Proxmox VM with QEMU Guest Agent enabled.
- The QGA Windows package installed and its service running automatically.
- Windows PowerShell and the built-in Windows Update Agent.
- Working access to Microsoft Update or the configured WSUS source.
- Enough free space on the Windows system volume for servicing and update
  staging.
- A backup or snapshot before the first mutating update.

The updater reports a total Windows update count. It does not invent a
normal/security split, does not update third-party applications, and does not
use winget. Windows may require multiple update and reboot rounds.

## Prepare the VM

1. In the Proxmox GUI, select the VM and open **Options**.
2. Enable **QEMU Guest Agent** and apply the setting.
3. Install the official QEMU Guest Agent package from the VirtIO Windows
   driver media or another approved VirtIO source.
4. In an elevated PowerShell, find and inspect the installed agent service:

   ```powershell
   Get-Service | Where-Object {$_.Name -match 'qemu|guest'} |
     Format-Table Name,Status,StartType
   ```

   The exact service name depends on the VirtIO package version. Confirm that
   it is running and configured for automatic startup, then reboot Windows if
   the installer requests it.

Check the Windows prerequisites:

```powershell
$PSVersionTable.PSVersion
Get-Service wuauserv,BITS,TrustedInstaller,UsoSvc
New-Object -ComObject Microsoft.Update.Session
```

Do not install PSWindowsUpdate or another PowerShell module for this feature.

## Verify QGA from Proxmox

Use the Proxmox node that owns the VM:

```text
qm agent <VMID> ping
qm guest cmd <VMID> get-osinfo
qm guest exec <VMID> --cmdline 'cmd.exe /c ver'
qm guest exec <VMID> --cmdline 'powershell.exe -NoLogo -NoProfile -NonInteractive -Command "whoami"'
```

The exact `qm guest exec` syntax can vary by PVE version; use the syntax
shown by `qm help guest exec` on that node. Confirm stdout, stderr, and the
exit code before using the updater. A responding agent without working
`guest-exec` is not sufficient.

## First check and update

1. Verify the VM backup or snapshot.
2. Run a read-only check and confirm that the target is detected as Windows,
   uses `qga`, and reports a plausible total count.
3. Start an update only after no previous servicing operation is active, no
   reboot is pending, and the system volume has sufficient space.
4. Monitor the job and retain the result codes. Windows installation can take
   substantially longer than a Linux package transaction.
5. The updater does not automatically reboot Windows. If it reports
   `reboot required`, schedule and perform the reboot deliberately, then run
   another check.

The updater performs a Windows-specific preflight before installation. A
pending reboot blocks a new run. Process names and CPU activity are not used as
the installation lock: a read-only COM search can legitimately start
`TrustedInstaller` or `TiWorker`.

## Windows update job lifecycle

The mutating operation is started by a short QGA command and then runs as a
detached PowerShell process in the guest. Its state is stored atomically as a
JSON file below:

```text
C:\ProgramData\Ultimate-Updater\WindowsUpdate\<job-id>.json
```

The state records the job ID, phase (`pending`, `search`, `download`,
`install`, `completed`, `failed`, or `unknown`), result codes, processed count,
reboot requirement, and the last message. A named Windows mutex and the
guest-state directory prevent two mutating Ultimate Updater jobs from running
at the same time. A repeated start request reuses an existing job ID. If a
controller starts with a new request while an active or unknown guest job is
found, it does not start another job; it adopts the existing job ID for
status recovery.

QGA status calls only read this state. Losing QGA or restarting the controller
does not prove that Windows Update stopped, so the updater does not issue a
second install or use `taskkill` as timeout recovery. The unresolved job stays
unknown/blocked until a later status read or deliberate operator recovery makes
the result clear. A QGA timeout is therefore not reported as a successful
installation.

The state file is not a substitute for a backup. Keep a recovery point before a
mutating update, and do not remove an `unknown` state merely to force a retry.
State metadata is updated atomically and carries the launcher/worker identity
across phase changes. If a start acknowledgement is lost, retain the state and
recover it explicitly; never start a second Windows mutation merely because the
original QGA request timed out.

## Troubleshooting

- **QGA not ready:** verify the Proxmox option, the Windows QGA service, and
  the VM boot state.
- **Guest execution failure:** test `cmd.exe` and PowerShell separately and
  inspect the QGA service context.
- **COM search failure:** check `wuauserv`, BITS, the update source, DNS, and
  system time.
- **Servicing-active preflight:** do not start a second update. Inspect
  TrustedInstaller/TiWorker and Windows Update logs; do not kill servicing
  processes as a recovery shortcut.
- **Component-store errors such as `0x800F0983`:** collect CBS and servicing
  diagnostics first. Do not delete `SoftwareDistribution` or run repair
  commands without a recovery plan.
- **Timeout:** preserve the recovery point and determine whether Windows is
  still servicing before retrying. A timeout is not proof that the update was
  rolled back.
- **Reboot required remains set:** complete the planned manual reboot and
  check again. Several Windows update rounds can be normal.

## Scope and limitations

The live validation covered Windows Server 2025 Standard Evaluation, not all
Windows editions or releases. The implementation uses the built-in COM API,
reports total updates only, does not automatically reboot, and does not
promise driver, firmware, Microsoft Store, or third-party application
updates. Keep the Windows VM and a tested recovery point available for future
regression tests.
