#!/bin/bash

# Create or replace the local web UI administrator credential.
# Password input is never echoed or written to logs.
set -euo pipefail

AUTH_FILE="${UU_WEB_AUTH_FILE:-/etc/ultimate-updater/web-auth.json}"
USERNAME="${1:-}"

if [[ ! "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]]; then
  printf 'Usage: %s USERNAME\n' "$(basename "$0")" >&2
  exit 2
fi
if [[ "${EUID}" -ne 0 ]]; then
  printf 'web-auth: root is required\n' >&2
  exit 1
fi

read -r -s -p 'Password: ' PASSWORD
printf '\n' >&2
read -r -s -p 'Repeat password: ' PASSWORD_REPEAT
printf '\n' >&2
if [[ -z "$PASSWORD" || "$PASSWORD" != "$PASSWORD_REPEAT" || "${#PASSWORD}" -lt 12 ]]; then
  printf 'web-auth: passwords must match and contain at least 12 characters\n' >&2
  exit 1
fi

mkdir -p "$(dirname "$AUTH_FILE")"
umask 077
AUTH_FILE="$AUTH_FILE" AUTH_USER="$USERNAME" AUTH_PASSWORD="$PASSWORD" python3 - <<'PY'
import base64
import hashlib
import json
import os
import secrets
import tempfile
from pathlib import Path

path = Path(os.environ["AUTH_FILE"])
salt = secrets.token_bytes(16)
iterations = 210000
digest = hashlib.pbkdf2_hmac("sha256", os.environ["AUTH_PASSWORD"].encode(), salt, iterations)
payload = {
    "username": os.environ["AUTH_USER"],
    "algorithm": "pbkdf2-sha256",
    "iterations": iterations,
    "salt": base64.b64encode(salt).decode(),
    "password_hash": base64.b64encode(digest).decode(),
}
with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
    json.dump(payload, handle)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
    temporary = Path(handle.name)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
unset PASSWORD PASSWORD_REPEAT
printf 'web-auth: credential stored in %s\n' "$AUTH_FILE"
