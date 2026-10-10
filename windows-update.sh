#!/bin/bash

# Windows Update through QGA. The mutating operation is detached from the
# QGA request and reports durable state from ProgramData.

WINDOWS_POWERSHELL_INSTALL_WORKER() {
  local job_id="${1:-}"
  [[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  cat <<POWERSHELL
\$ErrorActionPreference = 'Stop'
\$jobId = '$job_id'
\$root = 'C:\ProgramData\Ultimate-Updater\WindowsUpdate'
\$statePath = Join-Path \$root ("\$jobId.json")
function Write-UUState([string]\$phase, [string]\$result, [int]\$processed, [bool]\$reboot, \$resultCode, [string]\$message) {
  \$startedAt = (Get-Date).ToUniversalTime().ToString('o')
  try { \$startedAt = (Get-Content -LiteralPath \$statePath -Raw | ConvertFrom-Json).started_at } catch {}
  \$state = [ordered]@{ job_id = \$jobId; phase = \$phase; result = \$result; processed = \$processed; reboot_required = \$reboot; result_code = \$resultCode; message = (\$message -replace '[\r\n|]',' '); launcher_pid = \$old.launcher_pid; worker_pid = \$old.worker_pid; started_at = \$startedAt; updated_at = (Get-Date).ToUniversalTime().ToString('o') }
  \$tmp = "\$statePath.tmp.\$PID"
  \$state | ConvertTo-Json -Compress | Set-Content -LiteralPath \$tmp -Encoding UTF8
  Move-Item -LiteralPath \$tmp -Destination \$statePath -Force
}
function Test-UURebootRequired {
  return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}
\$mutex = New-Object System.Threading.Mutex(\$false, 'Global\Ultimate-Updater-WindowsUpdate')
try {
  \$acquired = \$false
  for (\$attempt = 0; \$attempt -lt 30 -and -not \$acquired; \$attempt++) { \$acquired = \$mutex.WaitOne(1000) }
  if (-not \$acquired) { Write-UUState 'unknown' 'unknown' 0 (Test-UURebootRequired) \$null 'Another Windows update job owns the guest lock'; exit 22 }
  Write-UUState 'search' 'running' 0 \$false \$null ''
  \$session = New-Object -ComObject Microsoft.Update.Session
  \$available = \$session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0").Updates
  if (\$available.Count -eq 0) { Write-UUState 'completed' 'ok' 0 (Test-UURebootRequired) 2 'no updates'; exit 0 }
  Write-UUState 'download' 'running' 0 \$false \$null ''
  \$downloader = \$session.CreateUpdateDownloader(); \$downloader.Updates = \$available
  \$download = \$downloader.Download()
  if (\$download.ResultCode -notin 2,3) { Write-UUState 'failed' 'failed' 0 (Test-UURebootRequired) \$download.ResultCode "download failed (result \$([int]\$download.ResultCode))"; exit 23 }
  Write-UUState 'install' 'running' 0 \$false \$null ''
  \$installer = \$session.CreateUpdateInstaller(); \$installer.Updates = \$available
  \$installation = \$installer.Install(); \$failed = 0
  for (\$index = 0; \$index -lt \$available.Count; \$index++) { if (\$installation.GetUpdateResult(\$index).ResultCode -in 3,4,5) { \$failed++ } }
  \$reboot = [bool]\$installation.RebootRequired -or (Test-UURebootRequired); \$resultCode = [int]\$installation.ResultCode
  if (\$failed -gt 0 -or \$resultCode -in 4,5) { Write-UUState 'failed' 'failed' (\$available.Count - \$failed) \$reboot \$resultCode "\$failed update(s) failed"; exit 24 }
  Write-UUState 'completed' 'ok' \$available.Count \$reboot \$resultCode 'installed'; exit 0
} catch { Write-UUState 'failed' 'failed' 0 (Test-UURebootRequired) \$null \$_.Exception.Message; exit 25
} finally { if (\$mutex) { try { \$mutex.ReleaseMutex() } catch {} ; \$mutex.Dispose() } }
POWERSHELL
}

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
  $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and Type='Software' and IsHidden=0")
  Write-Output ("UU_WINDOWS|ok|{0}|{1}" -f $result.Updates.Count, (Test-UURebootRequired).ToString().ToLower()); exit 0
} catch { Write-Output ("UU_WINDOWS|error|0|false|{0}" -f ($_.Exception.Message -replace '[\r\n|]',' ')); exit 20 }
POWERSHELL
      ;;
    preflight)
      cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
function Test-UURebootRequired {
  return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}
try {
  if (Test-UURebootRequired) { Write-Output 'UU_WINDOWS|preflight|blocked|reboot-required'; exit 21 }
  # TiWorker/TrustedInstaller may appear after a read-only COM search. The
  # durable guest mutex/state, not process names or CPU, guards installs.
  Write-Output 'UU_WINDOWS|preflight|ok|ready'; exit 0
} catch { Write-Output ("UU_WINDOWS|preflight|error|{0}" -f ($_.Exception.Message -replace '[\r\n|]',' ')); exit 23 }
POWERSHELL
      ;;
    install-start)
      local job_id="${2:-}" worker worker_encoded
      [[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
      worker=$(WINDOWS_POWERSHELL_INSTALL_WORKER "$job_id") || return 1
      worker_encoded=$(printf '%s' "$worker" | python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16le")).decode())') || return 1
      cat <<POWERSHELL
\$ErrorActionPreference = 'Stop'
\$jobId = '$job_id'; \$root = 'C:\ProgramData\Ultimate-Updater\WindowsUpdate'; \$statePath = Join-Path \$root ("\$jobId.json")
\$mutex = New-Object System.Threading.Mutex(\$false, 'Global\Ultimate-Updater-WindowsUpdate-Start')
try {
  if (-not \$mutex.WaitOne(10000)) { Write-Output 'UU_WINDOWS|start|blocked|start-lock'; exit 22 }
  New-Item -ItemType Directory -Path \$root -Force | Out-Null
  \$acl = Get-Acl -LiteralPath \$root
  \$acl.SetAccessRuleProtection(\$true, \$false)
  foreach (\$sid in @('S-1-5-18','S-1-5-32-544')) {
    \$identity = New-Object System.Security.Principal.SecurityIdentifier(\$sid)
    \$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(\$identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    \$acl.SetAccessRule(\$rule)
  }
  Set-Acl -LiteralPath \$root -AclObject \$acl
  \$active = \$false; \$existing = \$null; \$activeCandidate = \$null
  foreach (\$file in Get-ChildItem -LiteralPath \$root -Filter '*.json' -ErrorAction SilentlyContinue) {
    try { \$candidate = Get-Content -LiteralPath \$file.FullName -Raw | ConvertFrom-Json } catch { throw ('Unreadable Windows update state: ' + \$file.Name) }
    if (\$candidate.phase -in @('pending','search','download','install','unknown')) { \$active = \$true; if (-not \$activeCandidate) { \$activeCandidate = \$candidate }; if ([string]\$candidate.job_id -eq \$jobId) { \$existing = \$candidate } }
  }
  if (\$active) { if (\$existing) { Write-Output ("UU_WINDOWS|start|existing|{0}|{1}" -f \$jobId, \$existing.phase); exit 0 }; Write-Output ("UU_WINDOWS|start|existing-active|{0}|{1}" -f \$activeCandidate.job_id, \$activeCandidate.phase); exit 0 }
  \$state = [ordered]@{ job_id = \$jobId; phase = 'pending'; result = 'running'; processed = 0; reboot_required = \$false; result_code = \$null; message = 'worker launch pending'; launcher_pid = \$PID; worker_pid = \$null; started_at = (Get-Date).ToUniversalTime().ToString('o'); updated_at = (Get-Date).ToUniversalTime().ToString('o') }
  \$tmp = "\$statePath.tmp.\$PID"; \$state | ConvertTo-Json -Compress | Set-Content -LiteralPath \$tmp -Encoding UTF8; Move-Item -LiteralPath \$tmp -Destination \$statePath -Force
  \$process = Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand','$worker_encoded') -WindowStyle Hidden -PassThru
  \$state.worker_pid = \$process.Id; \$state.message = 'worker started'; \$state.updated_at = (Get-Date).ToUniversalTime().ToString('o')
  \$tmp = "\$statePath.tmp.\$PID"; \$state | ConvertTo-Json -Compress | Set-Content -LiteralPath \$tmp -Encoding UTF8; Move-Item -LiteralPath \$tmp -Destination \$statePath -Force
  Write-Output ("UU_WINDOWS|start|started|{0}|{1}" -f \$jobId, \$process.Id); exit 0
} catch {
  try {
    if (Test-Path -LiteralPath \$statePath) {
      \$failed = Get-Content -LiteralPath \$statePath -Raw | ConvertFrom-Json
      \$failed.phase = 'unknown'; \$failed.result = 'unknown'; \$failed.message = 'worker launch was not confirmed'; \$failed.updated_at = (Get-Date).ToUniversalTime().ToString('o')
      \$tmp = "\$statePath.tmp.\$PID"; \$failed | ConvertTo-Json -Compress | Set-Content -LiteralPath \$tmp -Encoding UTF8; Move-Item -LiteralPath \$tmp -Destination \$statePath -Force
    }
  } catch {}
  Write-Output ("UU_WINDOWS|start|error|{0}" -f (\$_.Exception.Message -replace '[\r\n|]',' ')); exit 23
} finally { if (\$mutex) { try { \$mutex.ReleaseMutex() } catch {} ; \$mutex.Dispose() } }
POWERSHELL
      ;;
    install-status)
      local job_id="${2:-}"
      [[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
      cat <<POWERSHELL
\$ErrorActionPreference = 'Stop'; \$jobId = '$job_id'; \$path = Join-Path 'C:\ProgramData\Ultimate-Updater\WindowsUpdate' ("\$jobId.json")
try {
  if (-not (Test-Path -LiteralPath \$path -PathType Leaf)) { Write-Output ("UU_WINDOWS|status|{0}|unknown|0|false|unknown|state-missing" -f \$jobId); exit 0 }
  \$state = Get-Content -LiteralPath \$path -Raw | ConvertFrom-Json
  if (\$state.phase -eq 'pending' -and -not \$state.worker_pid) {
    \$launcherAlive = \$false
    if (\$state.launcher_pid) { try { Get-Process -Id ([int]\$state.launcher_pid) -ErrorAction Stop | Out-Null; \$launcherAlive = \$true } catch {} }
    if (-not \$launcherAlive) { Write-Output ("UU_WINDOWS|status|{0}|unknown|0|false|unknown|worker-start-not-confirmed" -f \$jobId); exit 0 }
  }
  \$message = ([string]\$state.message -replace '[\r\n|]',' ')
  Write-Output ("UU_WINDOWS|status|{0}|{1}|{2}|{3}|{4}|{5}" -f \$jobId, \$state.phase, \$state.processed, ([string]\$state.reboot_required).ToLower(), \$state.result, \$message); exit 0
} catch { Write-Output ("UU_WINDOWS|status|{0}|unknown|0|false|unknown|state-invalid" -f \$jobId); exit 0 }
POWERSHELL
      ;;
    install) WINDOWS_POWERSHELL_SCRIPT install-start "${2:-legacy-job}" ;;
    *) return 2 ;;
  esac
}

WINDOWS_POWERSHELL_ENCODE() {
  local action="${1:-}" script
  shift || true
  script=$(WINDOWS_POWERSHELL_SCRIPT "$action" "$@") || return
  python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.buffer.read()).decode())' <<< "$script"
}
