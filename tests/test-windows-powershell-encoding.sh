#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/windows-update.sh"

encoded=$(WINDOWS_POWERSHELL_ENCODE check)
[[ -n "$encoded" ]]

printf '%s' "$encoded" | python3 -c '
import base64
import sys

script = base64.b64decode(sys.stdin.read()).decode("utf-16le")
assert "Microsoft.Update.Session" in script
assert "UU_WINDOWS|ok|" in script
assert "\x00" not in script
' 

install_encoded=$(WINDOWS_POWERSHELL_ENCODE install-start uu-986-20261011082406-3181422-32767)
[[ "${#install_encoded}" -lt 30000 ]]
printf '%s' "$install_encoded" | python3 -c '
import base64
import gzip
import re
import sys

launcher = base64.b64decode(sys.stdin.read()).decode("utf-16le")
match = re.search(r"FromBase64String\(\x27([^\x27]+)\x27\)", launcher)
assert match, launcher
worker = gzip.decompress(base64.b64decode(match.group(1))).decode("utf-16le")
assert "Microsoft.Update.Session" in worker
assert "Write-UUState" in worker
assert "Start-Process powershell.exe" in launcher
assert "GzipStream" in launcher
'

if UU_WINDOWS_MAX_ENCODED_COMMAND_CHARS=100 WINDOWS_POWERSHELL_ENCODE install-start short-job >/dev/null 2>&1; then
  echo 'oversized install-start payload was not rejected' >&2
  exit 1
fi

echo 'Windows PowerShell EncodedCommand UTF-16LE: PASS'
