#!/bin/bash

# Machine-readable status model for check-updates.sh.
# Records are deliberately kept separate from terminal/mail output so the
# existing user-facing behaviour and exit codes remain unchanged.

STATUS_MODEL_FILE="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
STATUS_MODEL_RECORD_FILE="${STATUS_MODEL_RECORD_FILE:-$LOCAL_FILES/.status-records.$$}"
STATUS_MODEL_NODE="${STATUS_MODEL_NODE:-${HOSTNAME:-}}"

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
  local node="${12:-$STATUS_MODEL_NODE}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
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
    "$(STATUS_MODEL_B64 "$error_message")" \
    "$(STATUS_MODEL_B64 "$node")" >> "$STATUS_MODEL_RECORD_FILE"
}

STATUS_MODEL_IMPORT_FILE() {
  local import_file="$1"
  python3 - "$import_file" "$STATUS_MODEL_RECORD_FILE" <<'PY'
import base64
import json
import sys

import_file, record_file = sys.argv[1:]
with open(import_file, encoding="utf-8") as source:
    payload = json.load(source)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise ValueError("status file has no target list")

def encode(value, null_value=""):
    if value is None:
        value = null_value
    elif isinstance(value, bool):
        value = "true" if value else "false"
    else:
        value = str(value)
    return base64.b64encode(value.encode()).decode()

with open(record_file, "a", encoding="utf-8") as records:
    for target in targets:
        if not isinstance(target, dict) or not target.get("id"):
            continue
        updates = target.get("updates")
        if isinstance(updates, dict):
            updates = updates.get("available")
        error = target.get("error")
        if not isinstance(error, dict):
            error = {}
        fields = [
            encode(target.get("id")),
            encode(target.get("type")),
            encode(target.get("transport")),
            encode(target.get("reachable"), "null"),
            encode(target.get("os")),
            encode(target.get("updater")),
            encode(updates, "null"),
            encode(target.get("reboot_required"), "null"),
            encode(target.get("check_status")),
            encode(error.get("code")),
            encode(error.get("message")),
            encode(target.get("node")),
        ]
        records.write("\t".join(fields) + "\n")
PY
}

STATUS_MODEL_FINISH() {
  local status_file="$STATUS_MODEL_FILE" record_file="$STATUS_MODEL_RECORD_FILE"
  python3 - "$record_file" "$status_file" "${STATUS_MODEL_PARTIAL:-false}" <<'PY'
import base64
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

record_file, status_file, partial = sys.argv[1:]
generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
targets = {}

if partial == "true":
    try:
        with open(status_file, encoding="utf-8") as source:
            payload = json.load(source)
        existing = payload.get("targets") if isinstance(payload, dict) else None
        if isinstance(existing, list):
            targets = {
                item.get("id"): item for item in existing
                if isinstance(item, dict) and item.get("id")
            }
    except (FileNotFoundError, OSError, ValueError):
        pass

def decode(value):
    return base64.b64decode(value.encode()).decode()

with open(record_file, encoding="utf-8") as records:
    for line in records:
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 12:
            raise ValueError("invalid status record")
        (target_id, target_type, transport, reachable, os_name, updater,
         updates, reboot_required, check_status, error_code, error_message,
         node) = map(decode, fields)
        available = None if updates in ("", "null") else int(updates)
        reboot = None if reboot_required in ("", "null") else reboot_required == "true"
        error = None
        if error_code or error_message:
            error = {"code": error_code or None, "message": error_message or None}
        record = targets.setdefault(target_id, {})
        record.update({
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
            "error": error,
            "node": node or None,
        })
        if partial != "true" or "last_update" not in record:
            record["last_update"] = {"status": "unknown", "timestamp": None}

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

# Render and optionally send one notification from the unified status model.
# The first output line is an internal decision marker; callers remove it
# before writing the human-readable mail body.
STATUS_MODEL_SEND_NOTIFICATION() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  local config_file="${2:-${LOCAL_FILES:-/etc/ultimate-updater}/update.conf}"
  local email_user email_sender email_no_updates email_only_security

  email_user=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$config_file" 2>/dev/null)
  email_sender=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' "$config_file" 2>/dev/null)
  email_no_updates=$(awk -F'"' '/^EMAIL_NO_UPDATES=/ {print $2}' "$config_file" 2>/dev/null)
  email_only_security=$(awk -F'"' '/^EMAIL_ONLY_SECURITY=/ {print $2}' "$config_file" 2>/dev/null)
  email_user="${email_user:-root}"
  email_sender="${email_sender:-$USER}"
  email_no_updates="${email_no_updates:-false}"
  email_only_security="${email_only_security:-false}"

  local notification state body
  notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$status_file") || return 1
  state=${notification%%$'\n'*}
  state=${state#STATE=}
  body=${notification#*$'\n'}

  # The status schema does not classify security updates. Preserve the
  # existing security-only policy by using the check output as the gate.
  if [[ "$email_only_security" == true ]]; then
    if [[ ! -f "${LOCAL_FILES:-/etc/ultimate-updater}/check-output" ]] ||
      ! grep -q 'S' "${LOCAL_FILES:-/etc/ultimate-updater}/check-output"; then
      return 0
    fi
  fi

  case "$state" in
    updates|issues)
      printf '%s\n' "$body" | mail -r "$email_sender" \
        -s "Ultimate Updater summary - $HOSTNAME" "$email_user" || true
      ;;
    current)
      if [[ "$email_no_updates" == true ]]; then
        echo "No updates found during search" | mail -r "$email_sender" \
          -s "Ultimate Updater" "$email_user" || true
      fi
      ;;
    empty)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

STATUS_MODEL_RENDER_NOTIFICATION() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  python3 - "$status_file" <<'PY'
import json
import sys

status_file = sys.argv[1]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError):
    raise SystemExit(1)

targets = payload.get("targets")
if not isinstance(targets, list):
    raise SystemExit(1)

updates = []
current = []
offline = []
unsupported = []
errors = []
not_checked = []
reboots = []
total = 0
has_known_count = False

def name(target):
    return str(target.get("id") or "unknown")

def short_error(target):
    error = target.get("error")
    if isinstance(error, dict):
        message = error.get("message") or error.get("code")
        if message:
            return str(message).replace("\n", " ").strip()
    return "check failed"

for target in targets:
    if not isinstance(target, dict):
        continue
    target_name = name(target)
    status = target.get("check_status") or "not_checked"
    reachable = target.get("reachable")
    values = target.get("updates")
    available = values.get("available") if isinstance(values, dict) else None
    count_known = isinstance(available, int) and not isinstance(available, bool)
    countable = status in ("ok", "updates_available")

    if countable and count_known:
        available = max(0, available)
        total += available
        has_known_count = True
        if available > 0:
            updates.append((target_name, available))
        elif status == "ok":
            current.append(target_name)
    if target.get("reboot_required") is True:
        reboots.append(target_name)

    if status == "offline" or reachable is False:
        offline.append(target_name)
    elif status == "unsupported":
        unsupported.append(target_name)
    elif status == "error":
        errors.append((target_name, short_error(target)))
    elif status == "not_checked":
        not_checked.append(target_name)

has_issues = bool(offline or unsupported or errors or not_checked)
if updates or reboots:
    state = "updates"
elif has_issues:
    state = "issues"
elif current and has_known_count:
    state = "current"
else:
    state = "empty"

lines = ["Ultimate Updater status", "=======================", ""]
if updates:
    lines.append("Available updates:")
    lines.extend(f"- {target}: {count}" for target, count in updates)
else:
    lines.append("Available updates: none")
if has_known_count:
    lines.extend(["", f"Total available updates: {total}"])
if current:
    lines.extend(["", "Current:"])
    lines.extend(f"- {target}" for target in current)
if reboots:
    lines.extend(["", "Reboot required:"])
    lines.extend(f"- {target}" for target in reboots)
if offline:
    lines.extend(["", "Not reachable:"])
    lines.extend(f"- {target}" for target in offline)
if errors:
    lines.extend(["", "Errors:"])
    lines.extend(f"- {target}: {message}" for target, message in errors)
if unsupported:
    lines.extend(["", "Unsupported:"])
    lines.extend(f"- {target}" for target in unsupported)
if not_checked:
    lines.extend(["", "Not checked:"])
    lines.extend(f"- {target}" for target in not_checked)

print(f"STATE={state}")
print("\n".join(lines))
PY
}
