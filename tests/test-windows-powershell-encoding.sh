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

echo 'Windows PowerShell EncodedCommand UTF-16LE: PASS'
