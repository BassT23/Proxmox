#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT_DIR/windows-update.sh"

# Generating the worker is safe; executing it is not. This test deliberately
# parses the generated text only and never passes it to qm guest exec.
worker=$(WINDOWS_POWERSHELL_INSTALL_WORKER syntax-fixture)
grep -Fq 'Microsoft.Update.Session' <<< "$worker"
grep -Fq '.Install()' <<< "$worker"
if grep -Fq 'qm guest exec' <<< "$worker"; then
  echo 'generated worker unexpectedly contains a guest-exec invocation' >&2
  exit 1
fi

if command -v pwsh >/dev/null 2>&1; then
  if ! printf '%s' "$worker" | pwsh -NoLogo -NoProfile -NonInteractive -Command '
    $text = [Console]::In.ReadToEnd()
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseInput(
      $text, [ref]$tokens, [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
      $errors | ForEach-Object { $_.Message }
      exit 1
    }
  '; then
    echo 'PowerShell parser rejected generated worker' >&2
    exit 1
  fi
  echo 'PowerShell worker parser test: PASS'
else
  echo 'PowerShell worker parser test: SKIP (pwsh unavailable; execution guard PASS)'
fi
