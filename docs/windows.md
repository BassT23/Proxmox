# Windows VMs

[← Back to supported systems](supported-systems.md) · [Checks and updates](checks-and-updates.md)

Windows support uses the Proxmox QEMU Guest Agent (QGA) and the Windows Update
Agent COM API. The tested path does not require an SSH server, WinRM,
PSWindowsUpdate, winget, or an additional Ultimate Updater agent in Windows.

## Validation status

The live test environment validated Windows Server 2025 Standard Evaluation
on VM 986 over the remote cluster path. QGA detection, `guest-exec`,
PowerShell, the built-in Windows Update COM search, the five-update count, and
reboot-state detection worked. A complete mutating update run was not accepted:
the first run exceeded the bounded timeout and Windows servicing continued
after the guest command ended. The component store diagnosis also reported
CBS error `0x800F0983`; `DISM /Online /Cleanup-Image /CheckHealth` reported no
detected corruption, while a later `ScanHealth` attempt lost its QGA session.
Treat the Windows path as validated for checks and as requiring a recovery
point and servicing diagnosis before an update.

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

The updater now performs a Windows-specific preflight before installation. It
blocks a new run when a pending reboot or common servicing processes
(`TrustedInstaller`, `TiWorker`, `MoUsoCoreWorker`, or `UsoClient`) indicate
that a previous operation may still be active. A running `wuauserv` service by
itself is not treated as proof of active servicing.

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
