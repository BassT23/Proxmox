#!/bin/bash

# Local, time-bound backup verification for External Linux updates.
# This file never contacts an External target and stores no credentials.

set -euo pipefail

STATE_FILE="${UU_EXTERNAL_BACKUP_STATE_FILE:-/var/lib/ultimate-updater/external-backup-verification.json}"
MAX_AGE_SECONDS="${UU_EXTERNAL_BACKUP_MAX_AGE:-86400}"
TARGET_RE='^[A-Za-z0-9][A-Za-z0-9_.-]*$'

usage() {
  printf 'Usage: %s verify TARGET [REFERENCE] | status TARGET | check TARGET [--override]\n' "$0" >&2
}

[[ "$MAX_AGE_SECONDS" =~ ^[0-9]+$ ]] || { printf 'Invalid backup verification age.\n' >&2; exit 64; }

case "${1:-}" in
  verify|status|check) ;;
  *) usage; exit 64 ;;
esac

target="${2:-}"
[[ "$target" =~ $TARGET_RE ]] || { printf 'Invalid External target.\n' >&2; exit 64; }
reference="${3:-}"
[[ ${#reference} -le 200 && "$reference" != *$'\n'* && "$reference" != *$'\r'* ]] || {
  printf 'Invalid backup reference.\n' >&2
  exit 64
}

if [[ "${1}" == verify ]]; then
  mkdir -p "$(dirname -- "$STATE_FILE")"
  chmod 0700 "$(dirname -- "$STATE_FILE")"
  python3 - "$STATE_FILE" "$target" "$reference" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

state_file, target, reference = sys.argv[1:]
try:
    with open(state_file, encoding="utf-8") as source:
        state = json.load(source)
except (FileNotFoundError, json.JSONDecodeError, OSError):
    state = {}
if not isinstance(state, dict):
    state = {}
now = datetime.now(timezone.utc).replace(microsecond=0)
state[target] = {
    "verified_at": now.isoformat().replace("+00:00", "Z"),
    "verified_by": "manual",
    "reference": reference,
}
directory = os.path.dirname(os.path.abspath(state_file)) or "."
fd, temporary = tempfile.mkstemp(prefix=".external-backup.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(state, output, indent=2, sort_keys=True)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, state_file)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
print(f"Backup verified manually for target {target} at {state[target]['verified_at']}")
PY
  exit 0
fi

override=false
if [[ "${1}" == check && "${3:-}" == --override ]]; then
  override=true
elif [[ "${1}" == check && -n "${3:-}" ]]; then
  usage
  exit 64
fi

result=$(python3 - "$STATE_FILE" "$target" "$MAX_AGE_SECONDS" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

state_file, target, max_age = sys.argv[1:]
try:
    with open(state_file, encoding="utf-8") as source:
        state = json.load(source)
    record = state.get(target, {}) if isinstance(state, dict) else {}
except (FileNotFoundError, json.JSONDecodeError, OSError):
    record = {}
verified_at = record.get("verified_at") if isinstance(record, dict) else None
status = "unknown"
age = ""
if isinstance(verified_at, str):
    try:
        timestamp = datetime.fromisoformat(verified_at.replace("Z", "+00:00"))
        seconds = int((datetime.now(timezone.utc) - timestamp).total_seconds())
        age = str(max(seconds, 0))
        status = "verified" if 0 <= seconds <= int(max_age) else "expired"
    except ValueError:
        status = "unknown"
print(json.dumps({
    "status": status,
    "verified_at": verified_at,
    "verified_by": record.get("verified_by") if isinstance(record, dict) else None,
    "reference": record.get("reference", "") if isinstance(record, dict) else "",
    "age_seconds": age,
}))
PY
)

if [[ "${1}" == status ]]; then
  printf '%s\n' "$result"
  exit 0
fi

if [[ "$override" == true ]]; then
  printf 'Backup safety override accepted for this run only.\n'
  exit 0
fi

status=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<<"$result")
if [[ "$status" == verified ]]; then
  printf 'Recent backup verification is valid for %s.\n' "$target"
  exit 0
fi
printf 'External update blocked: no verified recent backup for %s (%s).\n' "$target" "$status" >&2
exit 41
