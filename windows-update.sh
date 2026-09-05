#!/bin/bash

# Windows Update commands for the existing QEMU Guest Agent transport.
# The guest only needs Windows PowerShell and the built-in Windows Update COM
# API; no PowerShell module, SSH server, or WinRM endpoint is required.

WINDOWS_POWERSHELL_SCRIPT() {
  case "$1" in
    check)
      cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
function Test-UURebootRequired {
  return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}
try {
  $session = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
  $reboot = Test-UURebootRequired
  Write-Output ("UU_WINDOWS|ok|{0}|{1}" -f $result.Updates.Count, $reboot.ToString().ToLower())
  exit 0
} catch {
  $message = $_.Exception.Message -replace '[\r\n|]', ' '
  Write-Output ("UU_WINDOWS|error|0|false|{0}" -f $message)
  exit 20
}
POWERSHELL
      ;;
    install)
      cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
function Test-UURebootRequired {
  return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}
try {
  $session = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $available = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0").Updates
  if ($available.Count -eq 0) {
    Write-Output 'UU_WINDOWS|ok|0|false|no updates'
    exit 0
  }
  $downloader = $session.CreateUpdateDownloader()
  $downloader.Updates = $available
  $download = $downloader.Download()
  if ($download.ResultCode -notin 2, 3) {
    Write-Output ("UU_WINDOWS|error|0|false|download failed (result {0})" -f $download.ResultCode)
    exit 21
  }
  $installer = $session.CreateUpdateInstaller()
  $installer.Updates = $available
  $installation = $installer.Install()
  $failed = 0
  for ($index = 0; $index -lt $available.Count; $index++) {
    if ($installation.GetUpdateResult($index).ResultCode -in 3, 4, 5) { $failed++ }
  }
  $reboot = [bool]$installation.RebootRequired -or (Test-UURebootRequired)
  if ($failed -gt 0 -or $installation.ResultCode -in 4, 5) {
    Write-Output ("UU_WINDOWS|error|{0}|{1}|{2} update(s) failed" -f $failed, $reboot.ToString().ToLower(), $failed)
    exit 22
  }
  Write-Output ("UU_WINDOWS|ok|{0}|{1}|installed" -f $available.Count, $reboot.ToString().ToLower())
  exit 0
} catch {
  $message = $_.Exception.Message -replace '[\r\n|]', ' '
  Write-Output ("UU_WINDOWS|error|0|false|{0}" -f $message)
  exit 23
}
POWERSHELL
      ;;
    *) return 2 ;;
  esac
}

WINDOWS_POWERSHELL_ENCODE() {
  local action="$1" script
  script=$(WINDOWS_POWERSHELL_SCRIPT "$action") || return
  python3 -c 'import base64, sys; print(base64.b64encode(sys.stdin.read().encode("utf-16le")).decode())' <<< "$script"
}
