#!/bin/bash

# Machine-readable status model for check-updates.sh.
# Records are deliberately kept separate from terminal/mail output so the
# existing user-facing behaviour and exit codes remain unchanged.

STATUS_MODEL_FILE="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
STATUS_MODEL_RECORD_FILE="${STATUS_MODEL_RECORD_FILE:-$LOCAL_FILES/.status-records.$$}"

STATUS_MODEL_B64() {
  printf '%s' "${1:-}" | base64 | tr -d '\n'
}

STATUS_MODEL_INIT() {
  : > "$STATUS_MODEL_RECORD_FILE" || return 1
}

STATUS_MODEL_RECORD() {
  local id="$1" type="$2" transport="$3" reachable="$4" os="$5"
  local updater="$6" updates="$7" reboot_required="$8" check_status="$9"
  local error_code="${10:-}" error_message="${11:-}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(STATUS_MODEL_B64 "$id")" \
    "$(STATUS_MODEL_B64 "$type")" \
    "$(STATUS_MODEL_B64 "$transport")" \
    "$(STATUS_MODEL_B64 "$reachable")" \
    "$(STATUS_MODEL_B64 "$os")" \
    "$(STATUS_MODEL_B64 "$updater")" \
    "$(STATUS_MODEL_B64 "$updates")" \
    "$(STATUS_MODEL_B64 "$reboot_required")" \
    "$(STATUS_MODEL_B64 "$check_status")" \
    "$(STATUS_MODEL_B64 "$error_code")" \
    "$(STATUS_MODEL_B64 "$error_message")" >> "$STATUS_MODEL_RECORD_FILE"
}

STATUS_MODEL_FINISH() {
  local status_file="$STATUS_MODEL_FILE" record_file="$STATUS_MODEL_RECORD_FILE"
  python3 - "$record_file" "$status_file" <<'PY'
import base64
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

record_file, status_file = sys.argv[1:]
generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
targets = {}

def decode(value):
    return base64.b64decode(value.encode()).decode()

with open(record_file, encoding="utf-8") as records:
    for line in records:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 11:
            raise ValueError("invalid status record")
        (target_id, target_type, transport, reachable, os_name, updater,
         updates, reboot_required, check_status, error_code, error_message) = map(decode, fields)
        available = None if updates in ("", "null") else int(updates)
        reboot = None if reboot_required in ("", "null") else reboot_required == "true"
        error = None
        if error_code or error_message:
            error = {"code": error_code or None, "message": error_message or None}
        targets[target_id] = {
            "id": target_id,
            "type": target_type or None,
            "transport": transport or None,
            "reachable": None if reachable in ("", "null") else reachable == "true",
            "os": os_name or None,
            "os_version": None,
            "updater": updater or None,
            "updates": {"available": available},
            "reboot_required": reboot,
            "last_check": generated_at,
            "check_status": check_status or "not_checked",
            "last_update": {"status": "unknown", "timestamp": None},
            "error": error,
        }

payload = {"schema_version": 1, "generated_at": generated_at, "targets": list(targets.values())}
directory = os.path.dirname(os.path.abspath(status_file)) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, indent=2, sort_keys=False)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, status_file)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
  local result=$?
  if [[ $result -eq 0 ]]; then
    rm -f -- "$record_file"
  fi
  return "$result"
}

STATUS_MODEL_CLEANUP() {
  if [[ -n "${STATUS_MODEL_RECORD_FILE:-}" ]]; then
    rm -f -- "$STATUS_MODEL_RECORD_FILE"
  fi
}

STATUS_MODEL_UPSERT() {
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local target_id="$1" target_type="$2" transport="$3" reachable="$4"
  local os_name="$5" os_version="$6" updater="$7" updates="$8"
  local reboot_required="$9" check_status="${10}" error_code="${11:-}"
  local error_message="${12:-}"

  python3 - "$status_file" "$target_id" "$target_type" "$transport" \
    "$reachable" "$os_name" "$os_version" "$updater" "$updates" \
    "$reboot_required" "$check_status" "$error_code" "$error_message" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

(status_file, target_id, target_type, transport, reachable, os_name,
 os_version, updater, updates, reboot_required, check_status, error_code,
 error_message) = sys.argv[1:]

try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError):
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
    payload = {"schema_version": 1, "generated_at": None, "targets": []}

generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
payload["schema_version"] = payload.get("schema_version", 1)
payload["generated_at"] = generated_at
targets = payload["targets"]
record = next((item for item in targets if isinstance(item, dict) and item.get("id") == target_id), None)
if record is None:
    record = {"id": target_id}
    targets.append(record)

def nullable_bool(value):
    return None if value in ("", "null") else value == "true"

def nullable_int(value):
    return None if value in ("", "null") else int(value)

record.update({
    "type": target_type or None,
    "transport": transport or None,
    "reachable": nullable_bool(reachable),
    "os": os_name or None,
    "os_version": os_version or None,
    "updater": updater or None,
    "updates": {"available": nullable_int(updates)},
    "reboot_required": nullable_bool(reboot_required),
    "last_check": generated_at,
    "check_status": check_status or "not_checked",
    "error": ({"code": error_code or None, "message": error_message or None}
              if error_code or error_message else None),
})
record.setdefault("last_update", {"status": "unknown", "timestamp": None})

directory = os.path.dirname(os.path.abspath(status_file)) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, status_file)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

STATUS_MODEL_UPDATE_RESULT() {
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local target_id="$1" update_status="$2" exit_code="$3"
  python3 - "$status_file" "$target_id" "$update_status" "$exit_code" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

status_file, target_id, update_status, exit_code = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError):
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
targets = payload.setdefault("targets", [])
record = next((item for item in targets if isinstance(item, dict) and item.get("id") == target_id), None)
if record is None:
    record = {"id": target_id, "type": "external", "transport": "ssh"}
    targets.append(record)
timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
record["last_update"] = {"status": update_status, "timestamp": timestamp, "exit_code": int(exit_code)}
payload["generated_at"] = timestamp
directory = os.path.dirname(os.path.abspath(status_file)) or "."
os.makedirs(directory, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, status_file)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}
