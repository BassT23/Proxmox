#!/bin/bash

# Machine-readable status model for check-updates.sh.
# Records are deliberately kept separate from terminal/mail output so the
# existing user-facing behaviour remains unchanged.

STATUS_MODEL_FILE="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
STATUS_MODEL_RECORD_FILE="${STATUS_MODEL_RECORD_FILE:-$LOCAL_FILES/.status-records.$$}"
STATUS_MODEL_NODE="${STATUS_MODEL_NODE:-${HOSTNAME:-}}"

STATUS_MODEL_B64() {
  printf '%s' "${1:-}" | base64 | tr -d '\n'
}

STATUS_MODEL_INIT() {
  : > "$STATUS_MODEL_RECORD_FILE" || return 1
}

STATUS_MODEL_HAS_FAILURES() {
  [[ -f "$STATUS_MODEL_RECORD_FILE" ]] || return 1
  python3 - "$STATUS_MODEL_RECORD_FILE" <<'PY'
import base64
import sys

record_file = sys.argv[1]
with open(record_file, encoding="utf-8") as records:
    for line in records:
        fields = line.rstrip("\n").split("\t")
        if len(fields) < 9:
            continue
        try:
            status = base64.b64decode(fields[8]).decode()
        except (ValueError, UnicodeError):
            continue
        if status in ("offline", "error"):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

# Validate the semantic result for an explicitly requested target.  A helper
# returning zero is not sufficient for post-update capture: the target record
# must actually describe a reachable, checked target.
STATUS_MODEL_VALIDATE_TARGET_FILE() {
  local status_file="$1" target_id="$2"
  python3 - "$status_file" "$target_id" <<'PY'
import json
import sys

status_file, target_id = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except FileNotFoundError:
    print(f"POST_UPDATE_CAPTURE_STATUS_MISSING: {status_file}", file=sys.stderr)
    raise SystemExit(86)
except (OSError, ValueError) as exc:
    print(f"POST_UPDATE_CAPTURE_STATUS_INVALID: {status_file}: {exc}", file=sys.stderr)
    raise SystemExit(87)

targets = payload.get("targets") if isinstance(payload, dict) else None
record = next((item for item in targets or []
               if isinstance(item, dict) and str(item.get("id")) == target_id), None)
if record is None:
    print(f"POST_UPDATE_CAPTURE_TARGET_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(88)

check_status = record.get("check_status")
if check_status in (None, "", "not_checked", "skipped", "stopped"):
    print(
        f"POST_UPDATE_CAPTURE_NOT_CHECKED: target {target_id} has check_status={check_status or 'missing'}",
        file=sys.stderr,
    )
    raise SystemExit(89)
if record.get("reachable") is not True:
    print(
        f"POST_UPDATE_CAPTURE_NOT_REACHABLE: target {target_id} has reachable={record.get('reachable')}",
        file=sys.stderr,
    )
    raise SystemExit(90)
if not str(record.get("os") or "").strip():
    print(f"POST_UPDATE_CAPTURE_OS_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(91)
updates = record.get("updates")
if not isinstance(updates, dict) or "available" not in updates:
    print(f"POST_UPDATE_CAPTURE_UPDATES_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(92)
if "reboot_required" not in record:
    print(f"POST_UPDATE_CAPTURE_REBOOT_STATUS_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(93)
raise SystemExit(0)
PY
}

STATUS_MODEL_RECORD() {
  local id="$1" type="$2" transport="$3" reachable="$4" os="$5"
  local updater="$6" updates="$7" reboot_required="$8" check_status="$9"
  local error_code="${10:-}" error_message="${11:-}"
  local node="${12:-$STATUS_MODEL_NODE}"
  local name="${13:-${STATUS_MODEL_GUEST_NAME:-}}"
  local normal_updates="${14:-null}" security_updates="${15:-null}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
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
    "$(STATUS_MODEL_B64 "$node")" \
    "$(STATUS_MODEL_B64 "$name")" \
    "$(STATUS_MODEL_B64 "$normal_updates")" \
    "$(STATUS_MODEL_B64 "$security_updates")" >> "$STATUS_MODEL_RECORD_FILE"
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
            encode(target.get("name")),
            encode(target.get("normal_updates"), "null"),
            encode(target.get("security_updates"), "null"),
        ]
        last_update = target.get("last_update")
        if isinstance(last_update, dict):
            fields.append(encode(json.dumps(last_update, separators=(",", ":"))))
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
existing_targets = {}

try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
    existing = payload.get("targets") if isinstance(payload, dict) else None
    if isinstance(existing, list):
        existing_targets = {
            item.get("id"): item for item in existing
            if isinstance(item, dict) and item.get("id")
        }
        if partial == "true":
            targets = dict(existing_targets)
except (FileNotFoundError, OSError, ValueError):
    pass

def decode(value):
    return base64.b64decode(value.encode()).decode()

def is_newer_or_equal(candidate, current):
    if not isinstance(current, dict) or current.get("status") in (None, "unknown"):
        return True
    candidate_time = candidate.get("timestamp")
    current_time = current.get("timestamp")
    if not candidate_time or not current_time:
        return True
    try:
        candidate_dt = datetime.fromisoformat(candidate_time.replace("Z", "+00:00"))
        current_dt = datetime.fromisoformat(current_time.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return True
    return candidate_dt >= current_dt

with open(record_file, encoding="utf-8") as records:
    for line in records:
        fields = line.rstrip("\n").split("\t")
        if len(fields) not in (12, 13, 14, 15, 16):
            raise ValueError("invalid status record")
        (target_id, target_type, transport, reachable, os_name, updater,
         updates, reboot_required, check_status, error_code, error_message,
         node, *optional_fields) = map(decode, fields)
        name_fields = optional_fields[:1]
        imported_last_update = None
        normal_updates = security_updates = None
        optional_offset = 1
        # Records written before the split-update schema used the second
        # optional field for last_update. Keep those records readable.
        if len(optional_fields) > 1 and optional_fields[1].lstrip().startswith("{"):
            imported_last_update = json.loads(optional_fields[1])
            optional_offset = 3
        else:
            if len(optional_fields) > 1:
                normal_updates = None if optional_fields[1] in ("", "null") else int(optional_fields[1])
            if len(optional_fields) > 2:
                security_updates = None if optional_fields[2] in ("", "null") else int(optional_fields[2])
            if len(optional_fields) > 3 and optional_fields[3]:
                imported_last_update = json.loads(optional_fields[3])
        name = name_fields[0] if name_fields else ""
        available = None if updates in ("", "null") else int(updates)
        reboot = None if reboot_required in ("", "null") else reboot_required == "true"
        error = None
        # A stopped/paused target in a read-only inventory was intentionally
        # not checked.  Its explanatory record must not project as a current
        # failure or keep a stale CHECK_COMMAND_FAILED-style error visible.
        neutral_check = check_status in ("not_checked", "skipped", "stopped")
        if (error_code or error_message) and not neutral_check:
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
            **({"normal_updates": normal_updates} if len(optional_fields) > 1 and optional_offset == 1 else {}),
            **({"security_updates": security_updates} if len(optional_fields) > 2 and optional_offset == 1 else {}),
            "reboot_required": reboot,
            "last_check": generated_at,
            "check_status": check_status or "not_checked",
            "error": error,
            "node": node or None,
        })
        if target_type == "host":
            # Host identity comes from the cluster resolver, never from a
            # stale guest name carried by an older status record.
            record["name"] = node or target_id.removeprefix("host:")
        elif name:
            record["name"] = name
        if isinstance(imported_last_update, dict):
            imported_status = imported_last_update.get("status")
            existing_last_update = existing_targets.get(target_id, {}).get("last_update", {})
            existing_status = existing_last_update.get("status") if isinstance(existing_last_update, dict) else None
            # A remote partial check may legitimately have no local job
            # history.  Do not let that observation erase a terminal result
            # already known on the caller.
            if (imported_status != "unknown" or existing_status in (None, "unknown")) and \
               is_newer_or_equal(imported_last_update, existing_last_update):
                record["last_update"] = imported_last_update
        # A check refreshes observation fields, but must not erase the last
        # update result.  This applies to full checks as well as partial ones.
        if "last_update" not in record:
            record["last_update"] = existing_targets.get(target_id, {}).get(
                "last_update", {"status": "unknown", "timestamp": None}
            )

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
  email_sender=$(STATUS_MODEL_EXPAND_SENDER "$email_sender")
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
      printf '%s\n' "$body" | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$email_sender" \
        -s "Ultimate Updater summary - $HOSTNAME" "$email_user" || true
      ;;
    current)
      if [[ "$email_no_updates" == true ]]; then
        echo "No updates found during search" | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$email_sender" \
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

# Send an update summary only after the caller has completed its post-update
# status refresh.  Update jobs use this instead of update.sh's EXIT-trap mail,
# so the summary is rendered from the fresh status model.
STATUS_MODEL_SEND_UPDATE_NOTIFICATION() {
  local status_file="${1:-${STATUS_MODEL_FILE:-${LOCAL_FILES:-/etc/ultimate-updater}/status.json}}"
  local config_file="${2:-${LOCAL_FILES:-/etc/ultimate-updater}/update.conf}"
  local email_user email_sender email_only_error notification state body

  email_user=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$config_file" 2>/dev/null)
  email_sender=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' "$config_file" 2>/dev/null)
  email_only_error=$(awk -F'"' '/^EMAIL_ONLY_ERROR=/ {print $2}' "$config_file" 2>/dev/null)
  email_user="${email_user:-root}"
  email_sender="${email_sender:-${USER:-root}}"
  email_sender=$(STATUS_MODEL_EXPAND_SENDER "$email_sender")
  email_only_error="${email_only_error:-false}"

  notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$status_file" update) || return 1
  state=${notification%%$'\n'*}
  state=${state#STATE=}
  body=${notification#*$'\n'}

  [[ "$email_only_error" == true && "$state" != issues ]] && return 0
  printf '%s\n' "$body" | mail -a 'Content-Type: text/plain; charset=UTF-8' \
    -a 'Content-Transfer-Encoding: 8bit' -r "$email_sender" \
    -s "Ultimate Updater summary - $HOSTNAME" "$email_user" || true
}

# Expand only the documented sender placeholder. Config is never evaluated as
# shell code; the resulting value remains a normal argument to mail(1).
STATUS_MODEL_EXPAND_SENDER() {
  local sender="${1:-}" runtime_user="${USER:-}"
  runtime_user="${runtime_user:-$(id -un 2>/dev/null || printf root)}"
  case "$sender" in
    \$USER) printf '%s' "$runtime_user" ;;
    *) printf '%s' "$sender" ;;
  esac
}

STATUS_MODEL_RENDER_NOTIFICATION() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  local run_type="${2:-check}"
  case "$run_type" in
    check|update) ;;
    *) return 2 ;;
  esac
  python3 - "$status_file" "$run_type" <<'PY'
import json
import sys

status_file, run_type = sys.argv[1:]
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

def target_name(target):
    target_id = str(target.get("id") or "unknown")
    value = str(target.get("name") or "").strip()
    if target_id.startswith("host:"):
        return str(target.get("node") or target_id[5:])
    if target.get("type") == "host":
        return str(target.get("node") or target_id.removeprefix("host:"))
    if target_id.startswith("guest:"):
        target_id = target_id[6:]
    return f"{target_id} · {value}" if value and value != target_id else target_id

def target_icon(target):
    if target.get("type") == "host":
        return "🖥️"
    if target.get("type") == "vm" and "windows" in str(target.get("os") or "").lower():
        return "🪟"
    if target.get("type") in ("lxc", "vm"):
        return "🐧"
    return "🌐"

def short_error(target):
    error = target.get("error")
    if isinstance(error, dict):
        message = error.get("message") or error.get("code")
        if message:
            return str(message).replace("\n", " ").strip()
    return "check failed"

def update_split(target):
    def value(name):
        candidate = target.get(name)
        if isinstance(candidate, int) and not isinstance(candidate, bool):
            return str(candidate)
        return "Unknown"
    return f"S: {value('security_updates')} / N: {value('normal_updates')}"

def update_result(target):
    result = target.get("last_update")
    return result if isinstance(result, dict) else {}

def update_status(target):
    result = update_result(target)
    status = str(result.get("status") or "").lower()
    if status in ("failed", "interrupted"):
        return "failed"
    if status in ("success", "completed"):
        return "success"
    return "unknown"

def update_line(target):
    result = update_result(target)
    if target.get("check_status") == "offline" or target.get("reachable") is False:
        return "⚠️", "Nicht erreichbar"
    status = update_status(target)
    if status == "failed":
        return "❌", "Update fehlgeschlagen"
    if status != "success":
        return "⚠️", "Ergebnis nicht verfügbar"
    if target.get("reboot_required") is True:
        return "⚠️", "Aktualisiert – Neustart erforderlich"
    values = target.get("updates")
    available = values.get("available") if isinstance(values, dict) else None
    if isinstance(available, int) and not isinstance(available, bool) and available == 0:
        return "✅", "Alles aktuell"
    updated = result.get("updated_packages")
    if isinstance(updated, int) and not isinstance(updated, bool) and updated >= 0:
        return "✅", f"{updated} Pakete aktualisiert"
    return "✅", "Erfolgreich aktualisiert"

if run_type == "update":
    hosts = []
    guest_current = 0
    guest_success = []
    guest_failed = []
    guest_offline = []
    guest_reboot = []
    for target in targets:
        if not isinstance(target, dict):
            continue
        is_host = target.get("type") == "host" or str(target.get("id") or "").startswith("host:")
        status = target.get("check_status") or "not_checked"
        reachable = target.get("reachable")
        if is_host:
            hosts.append(target)
            continue
        if status == "offline" or reachable is False:
            guest_offline.append(target)
            continue
        result_status = update_status(target)
        if result_status == "failed":
            guest_failed.append(target)
        elif result_status == "success":
            values = target.get("updates")
            available = values.get("available") if isinstance(values, dict) else None
            if target.get("reboot_required") is True:
                guest_reboot.append(target)
            elif isinstance(available, int) and not isinstance(available, bool) and available == 0:
                guest_current += 1
            else:
                guest_success.append(target)

    lines = ["Ultimate Updater update summary", "", "Nodes:"]
    for target in hosts:
        icon, message = update_line(target)
        lines.extend([f"{icon} {target_name(target)}", f"   {message}"])
    if guest_success:
        lines.extend(["", "Guests:"])
        for target in guest_success:
            icon, message = update_line(target)
            lines.extend([f"{icon} {target_icon(target)} {target_name(target)}", f"   {message}"])
    if guest_reboot:
        lines.extend(["", "Guests requiring reboot:"])
        for target in guest_reboot:
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", "   Aktualisiert – Neustart erforderlich"])
    if guest_failed:
        lines.extend(["", "Failed guests:"])
        for target in guest_failed:
            _, message = update_line(target)
            lines.extend([f"❌ {target_icon(target)} {target_name(target)}", f"   {message}"])
    if guest_offline:
        lines.extend(["", "Unreachable guests:"])
        for target in guest_offline:
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", "   Nicht erreichbar"])
    if guest_current:
        lines.extend(["", f"✅ {guest_current} weitere Systeme – alles aktuell"])
    print("STATE=issues" if any(update_status(target) == "failed" for target in hosts + guest_failed) or guest_offline else "STATE=updates")
    print("\n".join(lines))
    raise SystemExit(0)

for target in targets:
    if not isinstance(target, dict):
        continue
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
            updates.append((target, available))
        elif status == "ok":
            current.append(target)
    if target.get("reboot_required") is True:
        reboots.append(target)

    if status == "offline" or reachable is False:
        offline.append(target)
    elif status == "unsupported":
        unsupported.append(target)
    elif status == "error":
        errors.append((target, short_error(target)))
    elif status == "not_checked":
        not_checked.append(target)

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
    nodes_with_updates = {str(target.get("node") or "Unassigned") for target, _ in updates}
    rendered_ids = {str(target.get("id") or "") for target, _ in updates}
    for target in targets:
        is_host = target.get("type") == "host" or str(target.get("id") or "").startswith("host:")
        node = str(target.get("node") or "Unassigned")
        if is_host and node in nodes_with_updates and str(target.get("id") or "") not in rendered_ids and \
            target.get("reachable") is True and target.get("check_status") in ("ok", "updates_available"):
            updates.append((target, 0))
            rendered_ids.add(str(target.get("id") or ""))
    node_order = []
    grouped = {}
    for target, count in updates:
        node = str(target.get("node") or "Unassigned")
        if node not in grouped:
            grouped[node] = []
            node_order.append(node)
        grouped[node].append((target, count))
    for node in node_order:
        node_targets = grouped[node]
        node_target = next((target for target, _ in node_targets if target.get("type") == "host"), None)
        lines.extend(["", f"🖥️ {node}"])
        if node_target is not None:
            lines.append(update_split(node_target))
        else:
            lines.append(f"⬆️ {sum(count for _, count in node_targets)} Updates")
        for target, _ in node_targets:
            # The node heading already represents a host target. Do not
            # render the same host a second time as a guest-like row.
            if target.get("type") == "host":
                continue
            lines.append(f"{target_icon(target)} {target_name(target)}")
            lines.append(update_split(target))
            if target.get("reboot_required") is True:
                lines.append("🔄 Neustart erforderlich")
else:
    lines.append("Available updates: none")
if has_known_count:
    lines.extend(["", f"Total available updates: {total}"])
if current:
    lines.extend(["", "Current:"])
    count = len(current)
    noun = "weiteres System" if count == 1 else "weitere Systeme"
    lines.append(f"✅ {count} {noun} geprüft – keine Updates verfügbar")
if reboots:
    lines.extend(["", "Reboot required:"])
    lines.extend(f"🔄 {target_name(target)}" for target in reboots)
if offline:
    lines.extend(["", "Not reachable:"])
    lines.extend(f"⚠️ {target_icon(target)} {target_name(target)}" for target in offline)
if errors:
    lines.extend(["", "Errors:"])
    lines.extend(f"⚠️ {target_icon(target)} {target_name(target)}: {message}" for target, message in errors)
if unsupported:
    lines.extend(["", "Unsupported:"])
    lines.extend(f"⚠️ {target_name(target)}" for target in unsupported)
if not_checked:
    lines.extend(["", "Not checked:"])
    lines.extend(f"⚠️ {target_name(target)}" for target in not_checked)

print(f"STATE={state}")
print("\n".join(lines))
PY
}
