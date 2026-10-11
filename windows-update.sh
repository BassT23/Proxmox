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
  \$oldLauncherPid = \$null
  \$oldWorkerPid = \$null
  try {
    \$old = Get-Content -LiteralPath \$statePath -Raw | ConvertFrom-Json
    \$startedAt = \$old.started_at
    \$oldLauncherPid = \$old.launcher_pid
    \$oldWorkerPid = \$old.worker_pid
  } catch {}
  \$state = [ordered]@{ job_id = \$jobId; phase = \$phase; result = \$result; processed = \$processed; reboot_required = \$reboot; result_code = \$resultCode; message = (\$message -replace '[\r\n|]',' '); launcher_pid = \$oldLauncherPid; worker_pid = \$oldWorkerPid; started_at = \$startedAt; updated_at = (Get-Date).ToUniversalTime().ToString('o') }
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

WINDOWS_POWERSHELL_WORKER_COMPRESSED() {
  local job_id="${1:-}" worker
  worker=$(WINDOWS_POWERSHELL_INSTALL_WORKER "$job_id") || return 1
  # QGA/Windows receive the launcher as one command line.  Compress the
  # worker's UTF-16LE bytes before embedding them so the launcher remains
  # safely below CreateProcess and helper argument limits.
  printf '%s' "$worker" | python3 -c '
import base64
import gzip
import sys

payload = sys.stdin.buffer.read().decode().encode("utf-16le")
print(base64.b64encode(gzip.compress(payload, compresslevel=9)).decode())
'
}

WINDOWS_POWERSHELL_SCRIPT() {
  case "$1" in
    check)
      cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
function Get-UUKB([string]$text) {
  $seen = @{}
  foreach ($match in [regex]::Matches($text, '(?i)\bKB\d{4,10}\b')) {
    $value = $match.Value.ToUpperInvariant()
    if (-not $seen.ContainsKey($value)) { $seen[$value] = $true; Write-Output $value }
  }
}
function Get-UUOperation([int]$value) {
  switch ($value) { 1 { 'Installation' } 2 { 'Uninstallation' } default { "Unknown ($value)" } }
}
function Test-UURebootRequired {
  return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
    (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations')
}
try {
  $session = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
  try {
    $total = [int]$searcher.GetTotalHistoryCount()
    $limit = [Math]::Min(20, [Math]::Max(0, $total))
    $entries = @()
    if ($limit -gt 0) { $entries = @($searcher.QueryHistory(0, $limit)) }
    $history = @(
      foreach ($entry in $entries) {
        [ordered]@{
          date = if ($entry.Date) { $entry.Date.ToUniversalTime().ToString('o') } else { $null }
          title = [string]$entry.Title
          kb = @(Get-UUKB (([string]$entry.Title) + ' ' + ([string]$entry.Description)))
          operation = Get-UUOperation ([int]$entry.Operation)
          result_code = [int]$entry.ResultCode
          hresult = if ($null -eq $entry.HResult) { $null } else { [int]$entry.HResult }
          source = 'Windows Update Agent'
        }
      }
    )
    $historyPayload = [ordered]@{ source = 'Windows Update Agent'; queried_at = (Get-Date).ToUniversalTime().ToString('o'); entries = @($history) }
    $historyJson = $historyPayload | ConvertTo-Json -Compress -Depth 6
    $historyB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($historyJson))
    Write-Output ("UU_WINDOWS|history|{0}" -f $historyB64)
  } catch {
    Write-Output ("UU_WINDOWS|history-error|{0}" -f ($_.Exception.Message -replace '[\r\n|]',' '))
  }
  Write-Output ("UU_WINDOWS|ok|{0}|{1}" -f $result.Updates.Count, (Test-UURebootRequired).ToString().ToLower()); exit 0
} catch { Write-Output ("UU_WINDOWS|error|0|false|{0}" -f ($_.Exception.Message -replace '[\r\n|]',' ')); exit 20 }
POWERSHELL
      ;;
    history)
      local history_limit="${2:-20}"
      [[ "$history_limit" =~ ^[0-9]+$ ]] || return 2
      (( history_limit > 0 && history_limit <= 50 )) || return 2
cat <<POWERSHELL
\$ErrorActionPreference = 'Stop'
try {
function Get-UUKB([string]\$text) {
  \$seen = @{}
  foreach (\$match in [regex]::Matches(\$text, '(?i)\bKB\d{4,10}\b')) {
    \$value = \$match.Value.ToUpperInvariant()
    if (-not \$seen.ContainsKey(\$value)) { \$seen[\$value] = \$true; Write-Output \$value }
  }
}
function Get-UUOperation([int]\$value) {
  switch (\$value) { 1 { 'Installation' } 2 { 'Uninstallation' } default { "Unknown (\$value)" } }
}
  \$session = New-Object -ComObject Microsoft.Update.Session
  \$searcher = \$session.CreateUpdateSearcher()
  \$total = [int]\$searcher.GetTotalHistoryCount()
  \$limit = [Math]::Min($history_limit, [Math]::Max(0, \$total))
  \$entries = @()
  if (\$limit -gt 0) { \$entries = @(\$searcher.QueryHistory(0, \$limit)) }
  \$history = @(
    foreach (\$entry in \$entries) {
      [ordered]@{
        date = if (\$entry.Date) { \$entry.Date.ToUniversalTime().ToString('o') } else { \$null }
        title = [string]\$entry.Title
        kb = @(Get-UUKB (([string]\$entry.Title) + ' ' + ([string]\$entry.Description)))
        operation = Get-UUOperation ([int]\$entry.Operation)
        result_code = [int]\$entry.ResultCode
        hresult = if (\$null -eq \$entry.HResult) { \$null } else { [int]\$entry.HResult }
        source = 'Windows Update Agent'
      }
    }
  )
  \$payload = [ordered]@{ source = 'Windows Update Agent'; queried_at = (Get-Date).ToUniversalTime().ToString('o'); entries = @(\$history) }
  \$json = \$payload | ConvertTo-Json -Compress -Depth 6
  \$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(\$json))
  Write-Output ("UU_WINDOWS|history|{0}" -f \$b64); exit 0
} catch { Write-Output ("UU_WINDOWS|history-error|{0}" -f (\$_.Exception.Message -replace '[\r\n|]',' ')); exit 20 }
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
      local job_id="${2:-}" worker_encoded
      [[ "$job_id" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
      worker_encoded=$(WINDOWS_POWERSHELL_WORKER_COMPRESSED "$job_id") || return 1
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
\$compressedBytes = [Convert]::FromBase64String('$worker_encoded')
\$compressedStream = New-Object System.IO.MemoryStream(,\$compressedBytes)
\$gzip = New-Object System.IO.Compression.GzipStream(\$compressedStream,[System.IO.Compression.CompressionMode]::Decompress)
\$workerStream = New-Object System.IO.MemoryStream
\$gzip.CopyTo(\$workerStream)
\$gzip.Dispose(); \$compressedStream.Dispose()
\$workerEncoded = [Convert]::ToBase64String(\$workerStream.ToArray())
\$workerStream.Dispose()
\$process = Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',\$workerEncoded) -WindowStyle Hidden -PassThru
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
  \$resultCode = if (\$null -eq \$state.result_code) { 'null' } else { [string]\$state.result_code }
  Write-Output ("UU_WINDOWS|status|{0}|{1}|{2}|{3}|{4}|{5}|{6}" -f \$jobId, \$state.phase, \$state.processed, ([string]\$state.reboot_required).ToLower(), \$state.result, \$message, \$resultCode); exit 0
} catch { Write-Output ("UU_WINDOWS|status|{0}|unknown|0|false|unknown|state-invalid" -f \$jobId); exit 0 }
POWERSHELL
      ;;
    install) WINDOWS_POWERSHELL_SCRIPT install-start "${2:-legacy-job}" ;;
    *) return 2 ;;
  esac
}

WINDOWS_POWERSHELL_ENCODE() {
  local action="${1:-}" script encoded max_chars
  shift || true
  script=$(WINDOWS_POWERSHELL_SCRIPT "$action" "$@") || return
  # powershell.exe -EncodedCommand consumes UTF-16LE bytes, not UTF-8.
  # Keep this identical to the encoding used for the detached install worker.
  encoded=$(python3 -c 'import base64,sys; print(base64.b64encode(sys.stdin.read().encode("utf-16le")).decode())' <<< "$script") || return 1
  if [[ "$action" == install-start ]]; then
    max_chars="${UU_WINDOWS_MAX_ENCODED_COMMAND_CHARS:-30000}"
    if [[ ! "$max_chars" =~ ^[0-9]+$ ]] || (( ${#encoded} > max_chars )); then
      printf 'Windows install-start command exceeds the safe encoded-command limit (%s characters).\n' "$max_chars" >&2
      return 1
    fi
  fi
  printf '%s\n' "$encoded"
}
