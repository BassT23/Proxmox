#!/bin/bash

# Machine-readable status model for check-updates.sh.
# Records are deliberately kept separate from terminal/mail output so the
# existing user-facing behaviour remains unchanged.

STATUS_MODEL_FILE="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
STATUS_MODEL_RECORD_FILE="${STATUS_MODEL_RECORD_FILE:-$LOCAL_FILES/.status-records.$$}"
STATUS_MODEL_GENERATION_FILE="${STATUS_MODEL_GENERATION_FILE:-${STATUS_MODEL_RECORD_FILE}.generations}"
STATUS_MODEL_NODE="${STATUS_MODEL_NODE:-${HOSTNAME:-}}"

# Update baselines must come from a recent, successful package observation.
# Keep this window aligned with the API package-freshness default while
# allowing the already supported bounded API override to be used by local
# callers that explicitly provide it.
STATUS_MODEL_PACKAGE_FRESHNESS_DEFAULT_MAX_AGE_SECONDS=86400

STATUS_MODEL_CAPTURE_PACKAGE_BASELINE() {
  local status_file="$1" target_id="$2" target_type="${3:-}" target_node="${4:-}"
  python3 - "$status_file" "$target_id" "$target_type" "$target_node" \
    "${UU_API_PACKAGE_FRESHNESS_MAX_AGE_SECONDS:-$STATUS_MODEL_PACKAGE_FRESHNESS_DEFAULT_MAX_AGE_SECONDS}" <<'PY'
import json
import sys
from datetime import datetime, timezone

status_file, target_id, target_type, target_node, configured_max_age = sys.argv[1:]
try:
    max_age = int(configured_max_age)
except (TypeError, ValueError):
    max_age = 86400
if not 60 <= max_age <= 604800:
    max_age = 86400

try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(1)

matches = []
for item in targets:
    if not isinstance(item, dict) or str(item.get("id")) != target_id:
        continue
    if target_type and item.get("type") != target_type:
        continue
    if target_type and target_type != "external" and item.get("node") != target_node:
        continue
    matches.append(item)
if len(matches) != 1:
    raise SystemExit(1)

record = matches[0]
updates = record.get("updates")
available = updates.get("available") if isinstance(updates, dict) else None
if type(available) is not int or available < 0:
    raise SystemExit(1)
if record.get("check_status") not in {"ok", "updates_available"}:
    raise SystemExit(1)
if record.get("reachable") is not True:
    raise SystemExit(1)
if record.get("package_data_invalidated") is True:
    raise SystemExit(1)
if record.get("package_mutation_in_progress") is True:
    raise SystemExit(1)

now = datetime.now(timezone.utc)
timestamps = {}
for field in ("last_check", "package_checked_at"):
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise SystemExit(1)
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        raise SystemExit(1)
    if stamp.tzinfo is None:
        raise SystemExit(1)
    age = (now - stamp.astimezone(timezone.utc)).total_seconds()
    if age < -300 or age > max_age:
        raise SystemExit(1)
    timestamps[field] = stamp.astimezone(timezone.utc)

# Legacy records have no explicit invalidation marker.  In that case a
# non-neutral update result newer than the package observation makes the old
# count unsafe to use as an update baseline.
if "package_data_invalidated" not in record:
    last_update = record.get("last_update")
    if isinstance(last_update, dict):
        update_status = str(last_update.get("status") or "").lower()
        if update_status not in {"", "unknown", "pending"}:
            update_value = last_update.get("timestamp")
            try:
                update_stamp = datetime.fromisoformat(str(update_value).replace("Z", "+00:00"))
            except (TypeError, ValueError):
                raise SystemExit(1)
            if update_stamp.tzinfo is None or update_stamp.astimezone(timezone.utc) >= timestamps["package_checked_at"]:
                raise SystemExit(1)

print(available)
PY
}

STATUS_MODEL_B64() {
  printf '%s' "${1:-}" | base64 | tr -d '\n'
}

STATUS_MODEL_NEW_OPERATION_ID() {
  printf 'uu-op-%s-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%S%N')" "${BASHPID:-$$}" "${RANDOM:-0}"
}

STATUS_MODEL_INIT() {
  : > "$STATUS_MODEL_RECORD_FILE" || return 1
  # Capture the target mutation epoch before any check command runs. A check
  # that started before an update must not clear that update's invalidation.
  python3 - "$STATUS_MODEL_FILE" "$STATUS_MODEL_GENERATION_FILE" <<'PY'
import json
import sys

status_file, generation_file = sys.argv[1:]
generations = {}
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
    targets = payload.get("targets") if isinstance(payload, dict) else None
    if isinstance(targets, list):
        for target in targets:
            if not isinstance(target, dict) or not target.get("id"):
                continue
            generation_present = "package_mutation_generation" in target
            active_present = "package_mutation_in_progress" in target
            generation = target.get("package_mutation_generation", 0)
            active = target.get("package_mutation_in_progress", False)
            if generation_present and (type(generation) is not int or generation < 0):
                generation = None
            if active_present and type(active) is not bool:
                active = None
            generations[str(target["id"])] = {
                "generation": generation,
                "active": active,
                "operation_id": target.get("package_mutation_operation_id"),
                "generation_present": generation_present,
                "active_present": active_present,
                "operation_present": "package_mutation_operation_id" in target,
            }
except (OSError, ValueError, TypeError):
    generations = {}

with open(generation_file, "w", encoding="utf-8") as output:
    json.dump(generations, output, separators=(",", ":"))
PY
}

STATUS_MODEL_CAPTURE_TARGET_GENERATION() {
  local target_id="$1"
  STATUS_MODEL_CHECK_GENERATION=""
  STATUS_MODEL_CHECK_STARTED_DURING_MUTATION=""
  STATUS_MODEL_CHECK_OPERATION_ID=""
  if [[ -f "$STATUS_MODEL_GENERATION_FILE" || -f "$STATUS_MODEL_FILE" ]]; then
    local generation_output=""
    generation_output=$(python3 - "$STATUS_MODEL_GENERATION_FILE" "$STATUS_MODEL_FILE" "$target_id" <<'PY'
import json
import sys

generation_path, status_path, target_id = sys.argv[1:]
try:
    import os
    path = generation_path if generation_path and os.path.isfile(generation_path) else status_path
    with open(path, encoding="utf-8") as source:
        payload = json.load(source)
    if path == status_path:
        generations = {
            str(item.get("id")): {
                "generation": item.get("package_mutation_generation"),
                "active": item.get("package_mutation_in_progress"),
                "operation_id": item.get("package_mutation_operation_id"),
                "generation_present": "package_mutation_generation" in item,
                "active_present": "package_mutation_in_progress" in item,
                "operation_present": "package_mutation_operation_id" in item,
            }
            for item in payload.get("targets", [])
            if isinstance(item, dict) and item.get("id")
        }
    else:
        generations = payload
    entry = generations.get(target_id) if isinstance(generations, dict) else None
    if isinstance(entry, dict):
        generation = entry.get("generation", 0)
        active = entry.get("active", False)
        operation_id = entry.get("operation_id", "")
        if entry.get("generation_present") is False:
            generation = 0
        if entry.get("active_present") is False:
            active = False
        if type(generation) is int and generation >= 0 and type(active) is bool:
            print(generation, str(active).lower(), operation_id or "")
    elif path != status_path:
        # STATUS_MODEL_INIT creates a sidecar for every run.  A valid legacy
        # status file may not contain this target yet; its first check starts
        # in the initial, non-mutating epoch.  A malformed status file does
        # not get this fallback and therefore remains fail-closed.
        try:
            with open(status_path, encoding="utf-8") as source:
                status_payload = json.load(source)
            status_targets = status_payload.get("targets") if isinstance(status_payload, dict) else None
            if isinstance(status_targets, list):
                print(0, "false", "")
        except (FileNotFoundError, OSError, ValueError, TypeError):
            if not os.path.exists(status_path):
                print(0, "false", "")
except (OSError, ValueError, TypeError):
    pass
PY
    ) || generation_output=""
    if [[ -n "$generation_output" ]]; then
      read -r STATUS_MODEL_CHECK_GENERATION STATUS_MODEL_CHECK_STARTED_DURING_MUTATION STATUS_MODEL_CHECK_OPERATION_ID <<< "$generation_output" || true
    fi
  fi
  export STATUS_MODEL_CHECK_GENERATION STATUS_MODEL_CHECK_STARTED_DURING_MUTATION STATUS_MODEL_CHECK_OPERATION_ID
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
if check_status in (None, "", "not_checked", "skipped", "stopped", "error"):
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
if not isinstance(updates, dict) or type(updates.get("available")) is not int or updates.get("available") < 0:
    print(f"POST_UPDATE_CAPTURE_UPDATES_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(92)
if "reboot_required" not in record:
    print(f"POST_UPDATE_CAPTURE_REBOOT_STATUS_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(93)
if record.get("package_data_invalidated") is not False:
    print(f"POST_UPDATE_CAPTURE_PACKAGE_DATA_NOT_VALIDATED: target {target_id}", file=sys.stderr)
    raise SystemExit(94)
if not isinstance(record.get("package_checked_at"), str) or not record.get("package_checked_at"):
    print(f"POST_UPDATE_CAPTURE_PACKAGE_TIMESTAMP_MISSING: target {target_id}", file=sys.stderr)
    raise SystemExit(95)
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
  local windows_update="${16:-}"
  local package_checked_at="${17:-}"
  local package_data_invalidated="${18:-}"
  local package_check_generation="${19:-${STATUS_MODEL_CHECK_GENERATION:-}}"
  local package_check_started_during_mutation="${20:-${STATUS_MODEL_CHECK_STARTED_DURING_MUTATION:-}}"
  local package_mutation_operation_id="${21:-${UU_PACKAGE_MUTATION_OPERATION_ID:-${STATUS_MODEL_CHECK_OPERATION_ID:-}}}"
  local package_details_json="${22:-}"
  local status_metadata=""
  # A successful check must carry explicit package provenance into remote
  # status artifacts.  Remote completion is deliberately fail-closed when
  # this Boolean is absent, so make the successful check contract explicit at
  # the common record boundary instead of relying on every caller to remember
  # the positional field.
  if [[ -z "$package_data_invalidated" && "$package_checked_at" == now &&
    "$reachable" == true ]]; then
    case "$check_status" in
      ok|updates_available) package_data_invalidated=false ;;
    esac
  fi
  if [[ -n "$package_checked_at" || -n "$package_data_invalidated" ||
    -n "$package_check_generation" || -n "$package_check_started_during_mutation" ||
    -n "$package_mutation_operation_id" || -n "$package_details_json" ]]; then
    status_metadata=$(python3 - "$package_checked_at" "$package_data_invalidated" \
      "$package_check_generation" "$package_check_started_during_mutation" \
      "$package_mutation_operation_id" "$package_details_json" <<'PY'
import json
import sys

package_checked_at, package_data_invalidated, package_check_generation, started_during_mutation, operation_id, package_details_json = sys.argv[1:]
metadata = {}
if package_checked_at:
    metadata["package_checked_at"] = package_checked_at
if package_data_invalidated in ("true", "false"):
    metadata["package_data_invalidated"] = package_data_invalidated == "true"
if package_check_generation.isdigit():
    metadata["package_check_generation"] = int(package_check_generation)
if started_during_mutation in ("true", "false"):
    metadata["package_check_started_during_mutation"] = started_during_mutation == "true"
if operation_id:
    metadata["package_mutation_operation_id"] = operation_id
if package_details_json:
    try:
        metadata["packages"] = json.loads(package_details_json)
    except (TypeError, ValueError):
        metadata["packages"] = package_details_json
print(json.dumps(metadata, separators=(",", ":")))
PY
    ) || return 1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
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
    "$(STATUS_MODEL_B64 "$security_updates")" \
    "$(STATUS_MODEL_B64 "$windows_update")" >> "$STATUS_MODEL_RECORD_FILE"
  if [[ -n "$status_metadata" ]]; then
    printf '\t%s' "$(STATUS_MODEL_B64 "$status_metadata")" >> "$STATUS_MODEL_RECORD_FILE"
  fi
  printf '\n' >> "$STATUS_MODEL_RECORD_FILE"
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

def normalize_skip_reason(value):
    if not isinstance(value, dict):
        return None
    # Keep this optional metadata deliberately small and limited to the public
    # code/message shape.  It must not become a transport for arbitrary
    # remote status data.
    if set(value) - {"code", "message"}:
        return None
    code = value.get("code")
    message = value.get("message")
    if not isinstance(code, str) or not code or len(code) > 128:
        return None
    if message is not None and (not isinstance(message, str) or len(message) > 2048):
        return None
    return {"code": code, "message": message}

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
        skip_reason = normalize_skip_reason(target.get("skip_reason"))
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
        capability = target.get("security_split_supported")
        if not isinstance(capability, bool):
            capability = target.get("updater") == "apt"
        fields.append(encode(capability))
        last_update = target.get("last_update")
        if isinstance(last_update, dict):
            fields.append(encode(json.dumps(last_update, separators=(",", ":"))))
        windows_update = target.get("windows_update")
        if isinstance(windows_update, dict):
            fields.append(encode(json.dumps(windows_update, separators=(",", ":"))))
        if skip_reason is not None:
            fields.append(encode(json.dumps(skip_reason, separators=(",", ":"))))
        metadata = {"source": "status_import"}
        if isinstance(target.get("last_check"), str):
            metadata["last_check"] = target["last_check"]
        if isinstance(target.get("package_checked_at"), str):
            metadata["package_checked_at"] = target["package_checked_at"]
        if "package_data_invalidated" in target:
            # Preserve presence and the raw value.  A remote value with the
            # wrong JSON type is provenance failure, not an implicit false.
            metadata["package_data_invalidated_present"] = True
            metadata["package_data_invalidated"] = target["package_data_invalidated"]
        if isinstance(target.get("package_data_invalidated_at"), str):
            metadata["package_data_invalidated_at"] = target["package_data_invalidated_at"]
        if "package_mutation_generation" in target:
            metadata["package_check_generation_present"] = True
        if type(target.get("package_mutation_generation")) is int and target["package_mutation_generation"] >= 0:
            metadata["package_check_generation"] = target["package_mutation_generation"]
        if "package_mutation_in_progress" in target:
            metadata["package_check_started_during_mutation_present"] = True
        if type(target.get("package_mutation_in_progress")) is bool:
            metadata["package_check_started_during_mutation"] = target["package_mutation_in_progress"]
        if "package_mutation_operation_id" in target:
            metadata["package_mutation_operation_id_present"] = True
            metadata["package_mutation_operation_id"] = target["package_mutation_operation_id"]
        if "packages" in target:
            metadata["packages_present"] = True
            metadata["packages"] = target.get("packages")
        fields.append(encode(json.dumps(metadata, separators=(",", ":"))))
        records.write("\t".join(fields) + "\n")
PY
}

STATUS_MODEL_FINISH() {
  local status_file="$STATUS_MODEL_FILE" record_file="$STATUS_MODEL_RECORD_FILE"
  local status_lock_file="${status_file}.lock" status_lock_fd
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$record_file" "$status_file" "${STATUS_MODEL_PARTIAL:-false}" <<'PY'
import base64
import copy
import json
import os
import re
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
    if not isinstance(existing, list):
        raise ValueError("status file has no target list")
    existing_targets = {
        item.get("id"): item for item in existing
        if isinstance(item, dict) and item.get("id")
    }
    if partial == "true":
        # Target records contain nested dictionaries.  A shallow copy would
        # let the history-only merge mutate the preserved status in place.
        targets = copy.deepcopy(existing_targets)
except FileNotFoundError:
    pass
except (OSError, ValueError) as exc:
    # A partial capture must never turn an invalid global state into a
    # one-target snapshot. Leave the existing file untouched.
    if partial == "true":
        print(f"STATUS_MODEL_PARTIAL_REJECTED_EXISTING_STATE: {status_file}: {exc}", file=sys.stderr)
        raise SystemExit(94)

def decode(value):
    return base64.b64decode(value.encode()).decode()

def valid_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return value if parsed.tzinfo is not None else None

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

def valid_generation(value):
    return type(value) is int and value >= 0

def valid_operation_id(value):
    return isinstance(value, str) and bool(re.fullmatch(r"uu-op-[A-Za-z0-9T_.:-]{8,160}", value))

def valid_package_result(status, reachable_value, updates_value, error_value, timestamp_value):
    if status not in {"ok", "updates_available"}:
        return False
    if reachable_value != "true" or error_value:
        return False
    if not re.fullmatch(r"[0-9]+", updates_value or ""):
        return False
    if timestamp_value != "now" and valid_timestamp(timestamp_value) is None:
        return False
    return True

def normalize_packages(value, expected_count=None):
    if not isinstance(value, list) or len(value) > 10000:
        return None
    if expected_count is not None and len(value) != expected_count:
        return None
    result = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"name", "old_version", "new_version"}:
            return None
        normalized = {}
        for key in ("name", "old_version", "new_version"):
            field = item.get(key)
            if (not isinstance(field, str) or not field or len(field) > 512 or
                    any(ord(char) < 32 for char in field)):
                return None
            normalized[key] = field
        result.append(normalized)
    return result

with open(record_file, encoding="utf-8") as records:
    for line in records:
        fields = line.rstrip("\n").split("\t")
        if len(fields) not in (12, 13, 14, 15, 16, 17, 18, 19, 20):
            raise ValueError("invalid status record")
        (target_id, target_type, transport, reachable, os_name, updater,
         updates, reboot_required, check_status, error_code, error_message,
         node, *optional_fields) = map(decode, fields)
        imported_last_update = None
        normal_updates = security_updates = None
        security_split_supported = None
        windows_update = None
        imported_skip_reason = None
        imported_last_check = None
        imported_package_checked_at = None
        imported_package_data_invalidated = None
        imported_package_data_invalidated_present = False
        imported_package_data_invalidated_at = None
        imported_package_check_generation = None
        imported_package_check_generation_present = False
        imported_package_check_started_during_mutation = None
        imported_package_check_started_during_mutation_present = False
        imported_package_mutation_operation_id = None
        imported_package_mutation_operation_id_present = False
        imported_packages = None
        imported_packages_present = False
        imported_status_metadata = False

        def parse_json_field(value):
            if not value:
                return None, None, None, None
            try:
                parsed = json.loads(value)
            except (TypeError, ValueError):
                # Optional remote metadata must not make the complete target
                # record unimportable.  Core status fields remain usable.
                return None, None, None, None
            if (isinstance(parsed, dict) and parsed and
                    not set(parsed) - {"source", "last_check", "package_checked_at",
                                       "package_data_invalidated", "package_data_invalidated_at",
                                       "package_data_invalidated_present",
                                       "package_check_generation", "package_check_generation_present",
                                       "package_check_started_during_mutation",
                                       "package_check_started_during_mutation_present",
                                       "package_mutation_operation_id",
                                       "package_mutation_operation_id_present",
                                       "packages", "packages_present"}):
                return None, None, None, parsed
            if isinstance(parsed, dict) and isinstance(parsed.get("history"), list):
                return None, parsed, None, None
            if (isinstance(parsed, dict) and
                    not set(parsed) - {"code", "message"} and
                    isinstance(parsed.get("code"), str) and parsed.get("code")):
                code = parsed["code"]
                message = parsed.get("message")
                if len(code) <= 128 and (message is None or
                                         isinstance(message, str) and len(message) <= 2048):
                    return None, None, {"code": code, "message": message}, None
            return parsed, None, None, None

        def nullable_int(value):
            if value in ("", "null"):
                return None
            if not re.fullmatch(r"-?\d+", value):
                raise ValueError("invalid numeric optional status field")
            return int(value)

        def is_json_field(value):
            return value.lstrip().startswith(("{", "["))

        # Optional fields have had several compatible layouts over time:
        # name,last_update and name,normal_updates,security_updates,
        # security_split_supported,last_update,windows_update,skip_reason,
        # plus source timestamp metadata. Parse by shape, not by blindly
        # converting every field to an integer, so old records remain
        # importable when both JSON objects are present.
        name = optional_fields[0] if optional_fields else ""
        cursor = 1
        split_fields = False
        if cursor < len(optional_fields) and is_json_field(optional_fields[cursor]):
            imported_last_update, windows_update, imported_skip_reason, metadata = parse_json_field(optional_fields[cursor])
            if metadata:
                imported_last_check = metadata.get("last_check")
                imported_package_checked_at = metadata.get("package_checked_at")
                imported_package_data_invalidated = metadata.get("package_data_invalidated")
                imported_package_data_invalidated_present = metadata.get("package_data_invalidated_present") is True
                imported_package_data_invalidated_at = metadata.get("package_data_invalidated_at")
                imported_package_check_generation = metadata.get("package_check_generation")
                imported_package_check_generation_present = metadata.get("package_check_generation_present") is True
                imported_package_check_started_during_mutation = metadata.get("package_check_started_during_mutation")
                imported_package_check_started_during_mutation_present = metadata.get(
                    "package_check_started_during_mutation_present"
                ) is True
                imported_package_mutation_operation_id = metadata.get("package_mutation_operation_id")
                imported_package_mutation_operation_id_present = metadata.get(
                    "package_mutation_operation_id_present"
                ) is True
                imported_packages = metadata.get("packages")
                imported_packages_present = metadata.get("packages_present") is True or "packages" in metadata
                imported_status_metadata = metadata.get("source") == "status_import"
            cursor += 1
        else:
            if cursor < len(optional_fields):
                normal_updates = nullable_int(optional_fields[cursor])
                split_fields = True
                cursor += 1
            if cursor < len(optional_fields) and is_json_field(optional_fields[cursor]):
                imported_last_update, windows_update, imported_skip_reason, metadata = parse_json_field(optional_fields[cursor])
                if metadata:
                    imported_last_check = metadata.get("last_check")
                    imported_package_checked_at = metadata.get("package_checked_at")
                    imported_package_data_invalidated = metadata.get("package_data_invalidated")
                    imported_package_data_invalidated_present = metadata.get("package_data_invalidated_present") is True
                    imported_package_data_invalidated_at = metadata.get("package_data_invalidated_at")
                    imported_package_check_generation = metadata.get("package_check_generation")
                    imported_package_check_generation_present = metadata.get("package_check_generation_present") is True
                    imported_package_check_started_during_mutation = metadata.get("package_check_started_during_mutation")
                    imported_package_check_started_during_mutation_present = metadata.get(
                        "package_check_started_during_mutation_present"
                    ) is True
                    imported_package_mutation_operation_id = metadata.get("package_mutation_operation_id")
                    imported_package_mutation_operation_id_present = metadata.get(
                        "package_mutation_operation_id_present"
                    ) is True
                    imported_packages = metadata.get("packages")
                    imported_packages_present = metadata.get("packages_present") is True or "packages" in metadata
                    imported_status_metadata = metadata.get("source") == "status_import"
                cursor += 1
            elif cursor < len(optional_fields):
                security_updates = nullable_int(optional_fields[cursor])
                cursor += 1
            if cursor < len(optional_fields) and optional_fields[cursor] in ("true", "false"):
                security_split_supported = optional_fields[cursor] == "true"
                cursor += 1
            while cursor < len(optional_fields):
                candidate_last, candidate_windows, candidate_skip, metadata = parse_json_field(optional_fields[cursor])
                if candidate_windows is not None:
                    windows_update = candidate_windows
                elif candidate_skip is not None:
                    imported_skip_reason = candidate_skip
                elif metadata is not None:
                    imported_last_check = metadata.get("last_check")
                    imported_package_checked_at = metadata.get("package_checked_at")
                    imported_package_data_invalidated = metadata.get("package_data_invalidated")
                    imported_package_data_invalidated_present = metadata.get("package_data_invalidated_present") is True
                    imported_package_data_invalidated_at = metadata.get("package_data_invalidated_at")
                    imported_package_check_generation = metadata.get("package_check_generation")
                    imported_package_check_generation_present = metadata.get("package_check_generation_present") is True
                    imported_package_check_started_during_mutation = metadata.get("package_check_started_during_mutation")
                    imported_package_check_started_during_mutation_present = metadata.get(
                        "package_check_started_during_mutation_present"
                    ) is True
                    imported_package_mutation_operation_id = metadata.get("package_mutation_operation_id")
                    imported_package_mutation_operation_id_present = metadata.get(
                        "package_mutation_operation_id_present"
                    ) is True
                    imported_packages = metadata.get("packages")
                    imported_packages_present = metadata.get("packages_present") is True or "packages" in metadata
                    imported_status_metadata = metadata.get("source") == "status_import"
                elif imported_last_update is None:
                    imported_last_update = candidate_last
                cursor += 1
        available = None if updates in ("", "null") else int(updates)
        reboot = None if reboot_required in ("", "null") else reboot_required == "true"
        error = None
        skip_reason = None
        neutral_skip_codes = {
            "STOPPED_READ_ONLY", "PAUSED_READ_ONLY", "RUNNING_DISABLED",
            "CHECK_DISABLED", "CHECK_WITH_HOST_DISABLED", "NETWORK_UNAVAILABLE",
            "UNSUPPORTED_GUEST_OS", "NO_SUPPORTED_TRANSPORT",
        }
        # A stopped/paused target in a read-only inventory was intentionally
        # not checked.  Its explanatory record is neutral metadata, not a
        # current failure.  Keep actual errors as errors even for a neutral
        # check_status.
        neutral_check = check_status in ("not_checked", "skipped", "stopped")
        if neutral_check and error_code in neutral_skip_codes:
            skip_reason = {"code": error_code, "message": error_message or None}
        elif (error_code or error_message):
            error = {"code": error_code or None, "message": error_message or None}
        if neutral_check and imported_skip_reason is not None:
            skip_reason = imported_skip_reason
            error = None
        record = targets.setdefault(target_id, {})
        existing_record = existing_targets.get(target_id, {})
        if isinstance(existing_record, dict):
            existing_type = existing_record.get("type")
            existing_node = existing_record.get("node")
            if existing_type and target_type and existing_type != target_type:
                raise ValueError(f"target identity mismatch for {target_id}: type")
            if existing_type == "external" and target_type == "external" and existing_node not in (None, ""):
                raise ValueError(f"target identity mismatch for {target_id}: external node")
            if existing_node and check_status != "history_only" and (not node or existing_node != node):
                raise ValueError(f"target identity mismatch for {target_id}: node")
        record.update({
            "id": target_id,
            "type": target_type or None,
            "transport": transport or None,
            "reachable": None if reachable in ("", "null") else reachable == "true",
            "os": os_name or None,
            "os_version": None,
            "updater": updater or None,
            "updates": {"available": available},
            **({"normal_updates": normal_updates} if split_fields else {}),
            **({"security_updates": security_updates} if split_fields else {}),
            "reboot_required": reboot,
            "last_check": (
                valid_timestamp(imported_last_check)
                if valid_timestamp(imported_last_check)
                else existing_record.get("last_check") if imported_status_metadata and isinstance(existing_record, dict)
                else None if imported_status_metadata else generated_at
            ),
            "check_status": check_status or "not_checked",
            "error": error,
            "skip_reason": skip_reason,
            "node": node or None,
            "security_split_supported": security_split_supported
            if security_split_supported is not None else (
                updater == "apt" or security_updates is not None
            ),
        })
        existing_package_checked_at = existing_record.get("package_checked_at") if isinstance(existing_record, dict) else None
        if isinstance(existing_package_checked_at, str) and existing_package_checked_at:
            record["package_checked_at"] = existing_package_checked_at
        existing_invalidated = (
            existing_record.get("package_data_invalidated") is True
            if isinstance(existing_record, dict) else False
        )
        existing_invalidated_at = (
            valid_timestamp(existing_record.get("package_data_invalidated_at"))
            if isinstance(existing_record, dict) else None
        )
        existing_generation_present = (
            isinstance(existing_record, dict) and
            "package_mutation_generation" in existing_record
        )
        existing_generation = (
            existing_record.get("package_mutation_generation")
            if existing_generation_present else 0
        )
        existing_generation_valid = (
            not existing_generation_present or valid_generation(existing_generation)
        )
        if not existing_generation_valid:
            existing_generation = 0
        existing_mutation_active_present = (
            isinstance(existing_record, dict) and
            "package_mutation_in_progress" in existing_record
        )
        existing_mutation_active_valid = (
            not existing_mutation_active_present or
            type(existing_record.get("package_mutation_in_progress")) is bool
        )
        existing_mutation_active = (
            existing_record.get("package_mutation_in_progress") is True
            if isinstance(existing_record, dict) else False
        )
        existing_operation_present = (
            isinstance(existing_record, dict) and
            "package_mutation_operation_id" in existing_record
        )
        existing_operation_id = (
            existing_record.get("package_mutation_operation_id")
            if existing_operation_present else None
        )
        existing_operation_valid = (
            not existing_operation_present or valid_operation_id(existing_operation_id)
        )
        if isinstance(existing_record, dict) and "package_data_invalidated" in existing_record:
            record["package_data_invalidated"] = existing_record.get("package_data_invalidated")
        if isinstance(existing_record, dict) and valid_generation(existing_record.get("package_mutation_generation")):
            record["package_mutation_generation"] = existing_record["package_mutation_generation"]
        if isinstance(existing_record, dict) and type(existing_record.get("package_mutation_in_progress")) is bool:
            record["package_mutation_in_progress"] = existing_record["package_mutation_in_progress"]
        if isinstance(existing_record, dict) and "package_mutation_operation_id" in existing_record:
            record["package_mutation_operation_id"] = existing_record["package_mutation_operation_id"]
        if existing_invalidated_at and record.get("package_data_invalidated") is True:
            record["package_data_invalidated_at"] = existing_invalidated_at
        incoming_generation = imported_package_check_generation
        incoming_started_during_mutation = imported_package_check_started_during_mutation
        generation_matches = valid_generation(incoming_generation) and incoming_generation == existing_generation
        incoming_operation_id = imported_package_mutation_operation_id
        incoming_operation_valid = (
            not imported_package_mutation_operation_id_present or
            valid_operation_id(incoming_operation_id)
        )
        operation_matches = (
            existing_operation_valid and incoming_operation_valid and
            existing_operation_present and imported_package_mutation_operation_id_present and
            existing_operation_id == incoming_operation_id
        )
        package_timestamp = None
        if isinstance(imported_package_checked_at, str) and imported_package_checked_at:
            package_timestamp = (
                datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
                if imported_package_checked_at == "now" else valid_timestamp(imported_package_checked_at)
            )
        package_result_ok = valid_package_result(
            check_status, reachable, updates, error_code or error_message, imported_package_checked_at
        )
        imported_provenance_valid = (
            not imported_status_metadata or (
                imported_package_data_invalidated_present and
                type(imported_package_data_invalidated) is bool and
                imported_package_check_generation_present and
                valid_generation(incoming_generation) and
                imported_package_check_started_during_mutation_present and
                type(incoming_started_during_mutation) is bool and
                incoming_operation_valid
            )
        )
        # A remote worker has its own mutation generation.  It is not
        # comparable to the controller generation.  A remote post-check can
        # therefore complete a controller reservation only through the
        # persisted operation ID, exact target identity (checked above), and
        # an explicit inactive/validated source result.
        remote_operation_completion = (
            imported_status_metadata and package_result_ok and
            existing_operation_present and operation_matches and
            imported_package_check_generation_present and valid_generation(incoming_generation) and
            imported_package_check_started_during_mutation_present and
            incoming_started_during_mutation is False and
            imported_package_data_invalidated_present and
            imported_package_data_invalidated is False
        )
        # Controller and remote workers maintain independent generations.  A
        # matching number is therefore only meaningful for a local check.  A
        # remote result may clear an existing controller invalidation only
        # through the exact, validated operation-completion path above.
        if existing_invalidated:
            invalidation_clear_allowed = (
                remote_operation_completion if imported_status_metadata else generation_matches
            )
        else:
            invalidation_clear_allowed = True
        package_result_safe = (
            check_status != "history_only" and package_result_ok and
            incoming_started_during_mutation is not True and
            (not existing_mutation_active or remote_operation_completion) and
            existing_generation_valid and
            existing_mutation_active_valid and
            existing_operation_valid and
            valid_generation(incoming_generation) and
            imported_provenance_valid and
            invalidation_clear_allowed
        )
        if package_result_ok and not package_result_safe and isinstance(existing_record, dict):
            # A result from before/during a mutation is an observation, not a
            # new package state. Preserve the previous package provenance.
            for key in ("updates", "normal_updates", "security_updates", "packages", "package_checked_at",
                        "package_mutation_generation", "package_mutation_in_progress",
                        "package_mutation_operation_id", "package_data_invalidated", "package_data_invalidated_at"):
                if key in existing_record:
                    record[key] = copy.deepcopy(existing_record[key])
        elif package_result_safe and package_timestamp is not None:
            incoming_available = int(updates) if re.fullmatch(r"[0-9]+", updates or "") else None
            record["package_checked_at"] = package_timestamp
            record["package_mutation_generation"] = (
                existing_generation if remote_operation_completion else (
                    incoming_generation if valid_generation(incoming_generation) else existing_generation
                )
            )
            record["package_mutation_in_progress"] = False
            record["package_data_invalidated"] = False
            record.pop("package_data_invalidated_at", None)
            normalized_packages = normalize_packages(
                imported_packages, incoming_available
            ) if imported_packages_present else None
            # A successful check without a complete package-detail result is
            # still a valid count check, but it must not inherit an old list.
            record["packages"] = normalized_packages
        elif check_status != "history_only" and isinstance(existing_record, dict):
            # A neutral skip or a failed observation is not a package result.
            # Preserve the last known package data instead of replacing it with
            # null counts and a newer observation timestamp.
            for key in ("updates", "normal_updates", "security_updates", "packages", "package_checked_at",
                        "package_mutation_generation", "package_mutation_in_progress",
                        "package_mutation_operation_id", "package_data_invalidated", "package_data_invalidated_at"):
                if key in existing_record:
                    record[key] = copy.deepcopy(existing_record[key])

        if package_result_ok and not package_result_safe:
            # A valid-looking count without a complete operation provenance
            # is not safe to publish as fresh package data.  Keep historical
            # fields, but make the current observation fail closed.
            record["package_data_invalidated"] = True

        if check_status != "history_only" and imported_status_metadata:
            incoming_invalidated_at = valid_timestamp(imported_package_data_invalidated_at)
            if imported_package_data_invalidated is True:
                record["package_data_invalidated"] = True
                if incoming_invalidated_at:
                    record["package_data_invalidated_at"] = incoming_invalidated_at
            elif imported_package_data_invalidated is False and not package_result_safe and existing_invalidated:
                # A remote error, incomplete result, old result, or result
                # captured during a mutation cannot clear local invalidation.
                record["package_data_invalidated"] = True
                if existing_invalidated_at:
                    record["package_data_invalidated_at"] = existing_invalidated_at
        if check_status == "history_only" and isinstance(existing_record, dict):
            # A history refresh is read-only and must not replace the latest
            # check observation, update count, reboot flag, or error state.
            for key in ("name", "type", "transport", "reachable", "os", "os_version",
                        "updater", "updates", "normal_updates", "security_updates", "packages",
                        "reboot_required", "last_check", "check_status", "error", "skip_reason", "node",
                        "security_split_supported", "package_checked_at", "package_mutation_generation",
                        "package_mutation_in_progress", "package_mutation_operation_id"):
                if key in existing_record:
                    record[key] = existing_record[key]
            if "package_data_invalidated" in existing_record:
                record["package_data_invalidated"] = existing_record["package_data_invalidated"]
            if "package_data_invalidated_at" in existing_record:
                record["package_data_invalidated_at"] = existing_record["package_data_invalidated_at"]
        if target_type == "host":
            # Host identity comes from the cluster resolver, never from a
            # stale guest name carried by an older status record.
            record["name"] = node or target_id.removeprefix("host:")
        elif name and not (check_status == "history_only" and "name" in existing_record):
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
        if isinstance(windows_update, dict) and isinstance(windows_update.get("history"), list):
            record["windows_update"] = windows_update
        elif target_id in existing_targets and isinstance(existing_targets[target_id].get("windows_update"), dict):
            record["windows_update"] = existing_targets[target_id]["windows_update"]
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
  exec {status_lock_fd}>&-
  if [[ $result -eq 0 ]]; then
    rm -f -- "$record_file"
  fi
  return "$result"
}

STATUS_MODEL_CLEANUP() {
  if [[ -n "${STATUS_MODEL_RECORD_FILE:-}" ]]; then
    rm -f -- "$STATUS_MODEL_RECORD_FILE"
  fi
  if [[ -n "${STATUS_MODEL_GENERATION_FILE:-}" ]]; then
    rm -f -- "$STATUS_MODEL_GENERATION_FILE"
  fi
}

STATUS_MODEL_UPSERT() {
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local target_id="$1" target_type="$2" transport="$3" reachable="$4"
  local os_name="$5" os_version="$6" updater="$7" updates="$8"
  local reboot_required="$9" check_status="${10}" error_code="${11:-}"
  local error_message="${12:-}"
  local normal_updates="${13:-null}" security_updates="${14:-null}"
  local security_split_supported="${15:-false}"
  local package_checked_at="${16:-}"
  local package_check_generation="${17:-${STATUS_MODEL_CHECK_GENERATION:-}}"
  local package_check_started_during_mutation="${18:-${STATUS_MODEL_CHECK_STARTED_DURING_MUTATION:-}}"
  local package_details_json="${19:-}"

  local status_lock_file="${status_file}.lock" status_lock_fd
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi

  python3 - "$status_file" "$target_id" "$target_type" "$transport" \
    "$reachable" "$os_name" "$os_version" "$updater" "$updates" \
    "$reboot_required" "$check_status" "$error_code" "$error_message" \
    "$normal_updates" "$security_updates" "$security_split_supported" "$package_checked_at" \
    "$package_check_generation" "$package_check_started_during_mutation" "$package_details_json" <<'PY'
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

(status_file, target_id, target_type, transport, reachable, os_name,
 os_version, updater, updates, reboot_required, check_status, error_code,
 error_message, normal_updates, security_updates, security_split_supported,
 package_checked_at, package_check_generation, package_check_started_during_mutation,
 package_details_json) = sys.argv[1:]

try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except FileNotFoundError:
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
except (OSError, ValueError) as exc:
    print(f"STATUS_MODEL_UPSERT_REJECTED_EXISTING_STATE: {status_file}: {exc}", file=sys.stderr)
    raise SystemExit(94)
if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
    print(f"STATUS_MODEL_UPSERT_REJECTED_EXISTING_STATE: {status_file}: missing target list", file=sys.stderr)
    raise SystemExit(94)

generated_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
payload["schema_version"] = payload.get("schema_version", 1)
payload["generated_at"] = generated_at
targets = payload["targets"]
record = next((item for item in targets if isinstance(item, dict) and item.get("id") == target_id), None)
if record is None:
    record = {"id": target_id}
    targets.append(record)
elif record.get("type") and record.get("type") != target_type:
    print(f"STATUS_MODEL_UPSERT_REJECTED_IDENTITY: {target_id}: type mismatch", file=sys.stderr)
    raise SystemExit(46)
elif target_type == "external" and record.get("node") not in (None, ""):
    print(f"STATUS_MODEL_UPSERT_REJECTED_IDENTITY: {target_id}: external node mismatch", file=sys.stderr)
    raise SystemExit(46)

existing_package_state = {
    key: record[key] for key in (
        "updates", "normal_updates", "security_updates", "packages", "package_checked_at",
        "package_mutation_generation", "package_mutation_in_progress",
        "package_mutation_operation_id", "package_data_invalidated", "package_data_invalidated_at"
    ) if key in record
}

def nullable_bool(value):
    return None if value in ("", "null") else value == "true"

def nullable_int(value):
    return None if value in ("", "null") else int(value)

neutral_skip_codes = {
    "STOPPED_READ_ONLY", "PAUSED_READ_ONLY", "RUNNING_DISABLED",
    "CHECK_DISABLED", "CHECK_WITH_HOST_DISABLED", "NETWORK_UNAVAILABLE",
    "UNSUPPORTED_GUEST_OS", "NO_SUPPORTED_TRANSPORT",
}
neutral_check = check_status in ("not_checked", "skipped", "stopped")
skip_reason = None
error = None
if neutral_check and error_code in neutral_skip_codes:
    skip_reason = {"code": error_code, "message": error_message or None}
elif error_code or error_message:
    error = {"code": error_code or None, "message": error_message or None}

record.update({
    "type": target_type or None,
    "transport": transport or None,
    "reachable": nullable_bool(reachable),
    "os": os_name or None,
    "os_version": os_version or None,
    "updater": updater or None,
    "updates": {"available": nullable_int(updates)},
    "normal_updates": nullable_int(normal_updates),
    "security_updates": nullable_int(security_updates),
    "reboot_required": nullable_bool(reboot_required),
    "last_check": generated_at,
    "check_status": check_status or "not_checked",
    "error": error,
    "skip_reason": skip_reason,
    "security_split_supported": nullable_bool(security_split_supported),
})
record.setdefault("last_update", {"status": "unknown", "timestamp": None})

def valid_generation(value):
    return value.isdigit() and int(value) >= 0

def valid_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return value if parsed.tzinfo is not None else None

def valid_package_result():
    return (
        check_status in {"ok", "updates_available"} and
        reachable == "true" and
        updates.isdigit() and int(updates) >= 0 and
        not error_code and not error_message and
        (package_checked_at == "now" or valid_timestamp(package_checked_at) is not None)
    )

def normalize_packages(value, expected_count=None):
    if not isinstance(value, list) or len(value) > 10000:
        return None
    if expected_count is not None and len(value) != expected_count:
        return None
    result = []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"name", "old_version", "new_version"}:
            return None
        normalized = {}
        for key in ("name", "old_version", "new_version"):
            field = item.get(key)
            if (not isinstance(field, str) or not field or len(field) > 512 or
                    any(ord(char) < 32 for char in field)):
                return None
            normalized[key] = field
        result.append(normalized)
    return result

current_generation_present = "package_mutation_generation" in record
current_generation = record.get("package_mutation_generation", 0)
current_generation_valid = (
    not current_generation_present or (type(current_generation) is int and current_generation >= 0)
)
if not current_generation_valid:
    current_generation = 0
incoming_generation = int(package_check_generation) if valid_generation(package_check_generation) else None
generation_matches = incoming_generation is not None and incoming_generation == current_generation
mutation_active_present = "package_mutation_in_progress" in record
mutation_active_valid = (
    not mutation_active_present or type(record.get("package_mutation_in_progress")) is bool
)
mutation_active = record.get("package_mutation_in_progress") is True
invalidated = record.get("package_data_invalidated") is True
package_result_ok = valid_package_result()
package_result_safe = (
    package_result_ok and package_check_started_during_mutation != "true" and
    not mutation_active and current_generation_valid and mutation_active_valid and
    valid_generation(package_check_generation) and
    (not invalidated or generation_matches)
)
if package_result_safe:
    if package_checked_at == "now":
        record["package_checked_at"] = datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
    else:
        record["package_checked_at"] = package_checked_at
    record["package_mutation_generation"] = incoming_generation if incoming_generation is not None else current_generation
    record["package_mutation_in_progress"] = False
    record["package_data_invalidated"] = False
    record.pop("package_data_invalidated_at", None)
    try:
        package_details = json.loads(package_details_json) if package_details_json else None
    except (TypeError, ValueError):
        package_details = None
    record["packages"] = normalize_packages(package_details, int(updates)) if package_details is not None else None
elif existing_package_state:
    record.update(existing_package_state)
if package_result_ok and not package_result_safe:
    # A successful-looking result without a captured generation has no safe
    # relationship to the target's mutation epoch.
    record["package_data_invalidated"] = True

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
  local result=$?
  exec {status_lock_fd}>&-
  return "$result"
}

STATUS_MODEL_PRESERVE_UPDATE_RESULTS() {
  local source_file="$1" started_at="$2"
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$source_file" "$status_file" "$started_at" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime

source_file, status_file, started_at = sys.argv[1:]
try:
    with open(source_file, encoding="utf-8") as source:
        before = json.load(source)
    with open(status_file, encoding="utf-8") as source:
        current = json.load(source)
    started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

before_targets = before.get("targets") if isinstance(before, dict) else None
current_targets = current.get("targets") if isinstance(current, dict) else None
if not isinstance(before_targets, list) or not isinstance(current_targets, list):
    raise SystemExit(1)

current_by_id = {
    str(item.get("id")): item for item in current_targets
    if isinstance(item, dict) and item.get("id")
}
for item in before_targets:
    if not isinstance(item, dict):
        continue
    last_update = item.get("last_update")
    target_id = str(item.get("id") or "")
    timestamp = last_update.get("timestamp") if isinstance(last_update, dict) else None
    if not target_id or not isinstance(last_update, dict) or not timestamp:
        continue
    try:
        update_time = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        continue
    if update_time >= started and target_id in current_by_id:
        current_by_id[target_id]["last_update"] = last_update

directory = os.path.dirname(os.path.abspath(status_file)) or "."
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(current, output, indent=2)
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
  exec {status_lock_fd}>&-
  return "$result"
}

# Apply the update counts observed before a global update to terminal results
# produced by that run. Update commands commonly perform a post-update check
# before recording their result, so reading the live model at result time can
# incorrectly turn a real update into "Up to date". The baseline is only
# metadata for current-run results; it never creates or resurrects targets.
STATUS_MODEL_APPLY_PRE_UPDATE_COUNTS() {
  local baseline_file="$1" started_at="$2"
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$baseline_file" "$status_file" "$started_at" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime

baseline_file, status_file, started_at = sys.argv[1:]
try:
    with open(baseline_file, encoding="utf-8") as source:
        baseline = json.load(source)
    with open(status_file, encoding="utf-8") as source:
        current = json.load(source)
    started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
except (OSError, ValueError, TypeError):
    raise SystemExit(1)

baseline_targets = baseline.get("targets") if isinstance(baseline, dict) else None
current_targets = current.get("targets") if isinstance(current, dict) else None
if not isinstance(baseline_targets, list) or not isinstance(current_targets, list):
    raise SystemExit(1)

def candidates(target_id):
    value = str(target_id or "")
    return {value, value.removeprefix("host:"), value.removeprefix("guest:"),
            value.removeprefix("external:")}

baseline_by_id = {}
for item in baseline_targets:
    if isinstance(item, dict) and item.get("id"):
        for candidate in candidates(item["id"]):
            if candidate:
                baseline_by_id[candidate] = item

changed = False
for item in current_targets:
    if not isinstance(item, dict) or not item.get("id"):
        continue
    result = item.get("last_update")
    if not isinstance(result, dict) or str(result.get("status")) not in {
        "success", "completed", "failed", "interrupted"
    }:
        continue
    timestamp = result.get("timestamp")
    if not timestamp:
        continue
    try:
        update_time = datetime.fromisoformat(str(timestamp).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        continue
    if update_time < started:
        continue
    before = None
    for candidate in candidates(item["id"]):
        if candidate in baseline_by_id:
            before = baseline_by_id[candidate]
            break
    if not isinstance(before, dict):
        continue
    updates = before.get("updates")
    pending = updates.get("available") if isinstance(updates, dict) else None
    normal = before.get("normal_updates")
    security = before.get("security_updates")
    if isinstance(normal, int) and not isinstance(normal, bool) and \
       isinstance(security, int) and not isinstance(security, bool):
        pending = normal + security
    if not isinstance(pending, int) or isinstance(pending, bool) or pending < 0:
        continue
    if result.get("pending_before") != pending:
        result["pending_before"] = pending
        changed = True

if not changed:
    raise SystemExit(0)

directory = os.path.dirname(os.path.abspath(status_file)) or "."
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(current, output, indent=2)
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
  exec {status_lock_fd}>&-
  return "$result"
}

STATUS_MODEL_INVALIDATE_PACKAGE_DATA() {
  local target_id="$1" target_type="$2" target_node="${3:-}" operation_id="${4:-}"
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  [[ -n "$target_id" && -n "$target_type" ]] || return 2
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$status_file" "$target_id" "$target_type" "$target_node" "$operation_id" <<'PY'
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone

status_file, target_id, target_type, target_node, operation_id = sys.argv[1:]
status_exists = True
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except FileNotFoundError:
    status_exists = False
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
except (OSError, ValueError):
    raise SystemExit(1)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(1)

requested = str(target_id)
id_matches = [item for item in targets
              if isinstance(item, dict) and str(item.get("id")) == requested]
if target_type != "external" and not target_node:
    raise SystemExit(46)
if operation_id and not re.fullmatch(r"uu-op-[A-Za-z0-9T_.:-]{8,160}", operation_id):
    raise SystemExit(46)
matches = [item for item in id_matches
           if item.get("type") == target_type and
           ((target_type == "external" and item.get("node") in (None, "")) or
            (target_type != "external" and item.get("node") == target_node))]
if not status_exists:
    if targets:
        raise SystemExit(46)
    record = {
        "id": requested,
        "type": target_type,
        "node": target_node or None,
        "reachable": None,
        "updates": {"available": None},
        "check_status": "not_checked",
        "error": None,
        "skip_reason": None,
        "last_update": {"status": "unknown", "timestamp": None},
    }
    targets.append(record)
elif len(id_matches) != len(matches) or len(matches) != 1:
    # Do not let an ID-only alias select an External, VM, LXC, or other node.
    raise SystemExit(1)
else:
    record = matches[0]

generation = record.get("package_mutation_generation", 0)
if type(generation) is not int or generation < 0:
    generation = 0
record["package_mutation_generation"] = generation + 1
record["package_mutation_in_progress"] = True
if operation_id:
    record["package_mutation_operation_id"] = operation_id
else:
    record.pop("package_mutation_operation_id", None)

record["package_data_invalidated"] = True
record["package_data_invalidated_at"] = (
    datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")
)

directory = os.path.dirname(os.path.abspath(status_file)) or "."
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
  local result=$?
  exec {status_lock_fd}>&-
  return "$result"
}

STATUS_MODEL_COMPLETE_PACKAGE_MUTATION() {
  local target_id="$1" target_type="$2" target_node="${3:-}" operation_id="${4:-}"
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  [[ -n "$target_id" && -n "$target_type" ]] || return 2
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$status_file" "$target_id" "$target_type" "$target_node" "$operation_id" <<'PY'
import json
import os
import sys
import tempfile

status_file, target_id, target_type, target_node, operation_id = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError):
    raise SystemExit(1)
targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(1)
matches = [item for item in targets
           if isinstance(item, dict) and str(item.get("id")) == target_id and
           item.get("type") == target_type and
           ((target_type == "external" and item.get("node") in (None, "")) or
            (target_type != "external" and item.get("node") == target_node))]
if len(matches) != 1:
    raise SystemExit(46)
current_operation_present = "package_mutation_operation_id" in matches[0]
current_operation = matches[0].get("package_mutation_operation_id")
if current_operation_present and current_operation != operation_id:
    raise SystemExit(46)
matches[0]["package_mutation_in_progress"] = False
directory = os.path.dirname(os.path.abspath(status_file)) or "."
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
  local result=$?
  exec {status_lock_fd}>&-
  return "$result"
}

STATUS_MODEL_VALIDATE_PACKAGE_MUTATION_RESERVATION() {
  local target_id="$1" target_type="$2" target_node="${3:-}" operation_id="$4"
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  [[ -n "$target_id" && -n "$target_type" && -n "$operation_id" ]] || return 2
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -s "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$status_file" "$target_id" "$target_type" "$target_node" "$operation_id" <<'PY'
import json
import re
import sys

status_file, target_id, target_type, target_node, operation_id = sys.argv[1:]
if not re.fullmatch(r"uu-op-[A-Za-z0-9T_.:-]{8,160}", operation_id):
    raise SystemExit(46)
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError):
    raise SystemExit(1)
targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(1)
matches = [item for item in targets
           if isinstance(item, dict) and str(item.get("id")) == target_id
           and item.get("type") == target_type
           and ((target_type == "external" and item.get("node") in (None, "")) or
                (target_type != "external" and item.get("node") == target_node))]
if len(matches) != 1:
    raise SystemExit(46)
record = matches[0]
generation = record.get("package_mutation_generation")
if (type(generation) is not int or generation < 0 or
        record.get("package_data_invalidated") is not True or
        record.get("package_mutation_in_progress") is not True or
        record.get("package_mutation_operation_id") != operation_id):
    raise SystemExit(46)
raise SystemExit(0)
PY
  local result=$?
  exec {status_lock_fd}>&-
  return "$result"
}

STATUS_MODEL_UPDATE_RESULT() {
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local target_id="$1" update_status="$2" exit_code="$3"
  local result_code="${4:-}" reboot_required="${5:-}" processed="${6:-}"
  local pending_before_override="${7:-}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  if [[ -z "$pending_before_override" ]] && declare -p UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
    pending_before_override="${UPDATE_PENDING_BEFORE[$target_id]-}"
  fi
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$status_file" "$target_id" "$update_status" "$exit_code" \
    "$result_code" "$reboot_required" "$processed" "$pending_before_override" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

status_file, target_id, update_status, exit_code, result_code, reboot_required, processed, pending_override = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except FileNotFoundError:
    payload = {"schema_version": 1, "generated_at": None, "targets": []}
except (OSError, ValueError) as exc:
    print(f"STATUS_MODEL_UPDATE_REJECTED_EXISTING_STATE: {status_file}: {exc}", file=sys.stderr)
    raise SystemExit(94)
if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
    print(f"STATUS_MODEL_UPDATE_REJECTED_EXISTING_STATE: {status_file}: missing target list", file=sys.stderr)
    raise SystemExit(94)
targets = payload.setdefault("targets", [])
record = next((item for item in targets if isinstance(item, dict) and item.get("id") == target_id), None)
if record is None:
    record = {"id": target_id, "type": "external", "transport": "ssh"}
    targets.append(record)
timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
pending_before = None
existing_updates = record.get("updates")
if isinstance(existing_updates, dict):
    candidate = existing_updates.get("available")
    if isinstance(candidate, int) and not isinstance(candidate, bool):
        pending_before = candidate
baseline_error = None
effective_exit_code = int(exit_code)
requires_baseline = update_status in {"success", "completed", "completed_with_warnings"}
if requires_baseline:
    # A result-time read of updates.available is not a baseline: a post-check
    # may already have replaced it. Successful update states therefore need
    # an explicit, validated pending_before supplied by the update path.
    if not pending_override:
        baseline_error = (
            "PENDING_BEFORE_UNAVAILABLE",
            96,
            "pending_before baseline is missing; update success cannot be proven",
        )
    elif not pending_override.isdigit():
        baseline_error = (
            "PENDING_BEFORE_INVALID",
            97,
            "pending_before baseline is invalid; update success cannot be proven",
        )
    else:
        pending_before = int(pending_override)
elif pending_override:
    if not pending_override.isdigit():
        print("STATUS_MODEL_UPDATE_REJECTED_PENDING_COUNT", file=sys.stderr)
        raise SystemExit(95)
    pending_before = int(pending_override)
effective_status = "failed" if baseline_error else update_status
if baseline_error:
    error_code, effective_exit_code, error_message = baseline_error
    # Never expose the result-time count as if it were the missing baseline.
    pending_before = None
else:
    error_code = ""
    error_message = ""
# A successful updater command with no pending packages is a valid no-op,
# not an update success.  Keep the result explicit so job/API consumers do
# not mistake a completed wrapper for a completed package mutation.
if not baseline_error and pending_override and effective_status in ("success", "completed") and pending_before == 0:
    effective_status = "skipped"
last_update = {"status": effective_status, "timestamp": timestamp, "exit_code": effective_exit_code}
if pending_before is not None:
    last_update["pending_before"] = pending_before
if baseline_error:
    last_update["message"] = f"{error_code}: {error_message}"
elif result_code not in ("", "null"):
    last_update["result_code"] = int(result_code)
if not baseline_error and reboot_required in ("true", "false"):
    last_update["reboot_required"] = reboot_required == "true"
if not baseline_error and processed not in ("", "null"):
    last_update["processed"] = int(processed)
record["last_update"] = last_update
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
if baseline_error:
    print(f"{error_code}: {error_message}", file=sys.stderr)
    raise SystemExit(effective_exit_code)
PY
  local result=$?
  exec {status_lock_fd}>&-
  if [[ "$result" == 96 || "$result" == 97 ]]; then
    # Direct VM/QGA and legacy callers may intentionally ignore the function's
    # return value. Keep the enclosing update fail-closed as well.
    # shellcheck disable=SC2034 # consumed by the sourced update runner.
    UPDATE_FAILURE=true
  fi
  if [[ "$result" -eq 0 ]] && declare -p UPDATE_RESULT_RECORDED >/dev/null 2>&1; then
    local update_pending=""
    if declare -p UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
      update_pending="${UPDATE_PENDING_BEFORE[$target_id]-}"
    fi
    UPDATE_RESULT_RECORDED=true
    # These flags are consumed by the sourced update runner.
    # shellcheck disable=SC2034
    UPDATE_RESULT_TARGET="$target_id"
    if [[ "$update_status" == skipped || "$update_status" == unsupported ||
      "$update_pending" == 0 ]]; then
      # shellcheck disable=SC2034
      UPDATE_WARNING=true
    fi
  fi
  return "$result"
}

STATUS_MODEL_REBOOT_FAILURE() {
  local status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  local target_id="$1" exit_code="${2:-1}" message="${3:-Automatic reboot failed}"
  local status_lock_file="${status_file}.lock" status_lock_fd
  exec {status_lock_fd}>"$status_lock_file" || return 1
  if ! flock -x "$status_lock_fd"; then
    exec {status_lock_fd}>&-
    return 1
  fi
  python3 - "$status_file" "$target_id" "$exit_code" "$message" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone

status_file, target_id, exit_code, message = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError) as exc:
    print(f"STATUS_MODEL_REBOOT_FAILURE_REJECTED: {exc}", file=sys.stderr)
    raise SystemExit(94)
if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
    raise SystemExit(94)
record = next((item for item in payload["targets"]
               if isinstance(item, dict) and str(item.get("id")) == target_id), None)
if record is None:
    raise SystemExit(94)
last_update = record.get("last_update")
if not isinstance(last_update, dict):
    last_update = {}
last_update["status"] = "failed"
last_update["exit_code"] = int(exit_code)
last_update["reboot_error"] = message[:512]
last_update["reboot_required"] = True
last_update["reboot_attempted_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
record["last_update"] = last_update
payload["generated_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
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
  local result=$?
  exec {status_lock_fd}>&-
  return "$result"
}

# Optional, run-scoped diagnostics for the External update-all lifecycle.
# Disabled by default and deliberately limited to status metadata; this never
# changes the authoritative status model.
STATUS_MODEL_TRACE_EVENT() {
  [[ "${UU_EXTERNAL_LIFECYCLE_TRACE:-false}" == true ]] || return 0
  local trace_file="${UU_EXTERNAL_LIFECYCLE_TRACE_FILE:-}"
  local checkpoint="${1:-}" target_id="${2:-}" helper_rc="${3:-}"
  [[ -n "$trace_file" && -n "$checkpoint" ]] || return 0
  local trace_lock="${trace_file}.lock" trace_lock_fd
  mkdir -p -- "$(dirname -- "$trace_file")" 2>/dev/null || return 1
  exec {trace_lock_fd}>"$trace_lock" || return 1
  if ! flock -x "$trace_lock_fd"; then
    exec {trace_lock_fd}>&-
    return 1
  fi
  python3 - "$trace_file" "$checkpoint" "$target_id" "$helper_rc" \
    "${STATUS_MODEL_FILE:-${LOCAL_FILES:-/etc/ultimate-updater}/status.json}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

trace_file, checkpoint, requested_target, helper_rc, status_file = sys.argv[1:]
try:
    real_status = os.path.realpath(status_file)
except OSError:
    real_status = status_file
event_time = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
base = {
    "timestamp": event_time,
    "checkpoint": checkpoint,
    "status_file": status_file,
    "realpath": real_status,
    "helper_rc": int(helper_rc) if helper_rc.lstrip("-").isdigit() else (helper_rc or None),
}
try:
    stat = os.stat(status_file)
    base.update({"device": stat.st_dev, "inode": stat.st_ino, "size": stat.st_size,
                 "mtime": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()})
except OSError:
    base.update({"device": None, "inode": None, "size": None, "mtime": None})
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError):
    payload = {}
targets = payload.get("targets") if isinstance(payload, dict) else []
if not isinstance(targets, list):
    targets = []
selected = [item for item in targets if isinstance(item, dict) and
            ((not requested_target and item.get("type") == "external") or
             (requested_target and item.get("id") == requested_target))]
if not selected:
    selected = [{}]
for item in selected:
    result = item.get("last_update") if isinstance(item.get("last_update"), dict) else {}
    updates = item.get("updates") if isinstance(item.get("updates"), dict) else {}
    event = dict(base)
    event.update({
        "target_id": item.get("id") or requested_target or None,
        "generated_at": payload.get("generated_at") if isinstance(payload, dict) else None,
        "last_update_status": result.get("status"),
        "last_update_timestamp": result.get("timestamp"),
        "exit_code": result.get("exit_code"),
        "pending_before": result.get("pending_before"),
        "updates_available": updates.get("available"),
        "check_status": item.get("check_status"),
    })
    with open(trace_file, "a", encoding="utf-8") as output:
        json.dump(event, output, sort_keys=True)
        output.write("\n")
        output.flush()
PY
  local result=$?
  exec {trace_lock_fd}>&-
  return "$result"
}

# Return success only when the structured status model contains a positive
# security-update count in the notification scope.  Unknown, failed, and
# unreachable targets are not converted to zero by this gate.
STATUS_MODEL_HAS_SECURITY_UPDATES() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  local scope_target="${2:-}" scope_kind="${3:-}"
  python3 - "$status_file" "$scope_target" "$scope_kind" <<'PY'
import json
import sys

status_file, scope_target, scope_kind = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError):
    raise SystemExit(2)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(2)

def target_matches_scope(target):
    if not scope_target:
        return True
    wanted = str(scope_target)
    target_id = str(target.get("id") or "")
    if scope_kind == "node":
        if target.get("type") != "host":
            return False
        candidates = {wanted, wanted.removeprefix("host:"), wanted.removeprefix("node-")}
        values = {
            target_id,
            target_id.removeprefix("host:"),
            str(target.get("node") or ""),
            str(target.get("name") or ""),
        }
        return bool(candidates & values) or wanted == "host"
    candidates = {wanted, wanted.removeprefix("guest:"), wanted.removeprefix("host:")}
    values = {target_id, target_id.removeprefix("guest:"), target_id.removeprefix("host:")}
    return bool(candidates & values)

selected = [
    target for target in targets
    if isinstance(target, dict) and target_matches_scope(target)
]
if scope_target and not selected:
    raise SystemExit(2)

for target in selected:
    status = target.get("check_status")
    if status not in ("ok", "updates_available") or target.get("reachable") is not True:
        continue
    value = target.get("security_updates")
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

# Render the compact login summary from the structured status model.  The raw
# check log remains a diagnostic artifact and is intentionally not an input to
# this renderer.
STATUS_MODEL_RENDER_WELCOME() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  python3 - "$status_file" <<'PY'
import json
import os
import re
import sys

status_file = sys.argv[1]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError):
    print("Update status unavailable.")
    raise SystemExit(0)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    print("Update status unavailable.")
    raise SystemExit(0)

color_mode = os.environ.get("UU_WELCOME_COLOR", "auto").lower()
use_color = color_mode == "always" or (color_mode == "auto" and sys.stdout.isatty())
COLORS = {
    "cyan": "\033[36m",
    "green": "\033[1;92m",
    "orange": "\033[1;33m",
    "red": "\033[1;91m",
    "reset": "\033[0m",
}

def paint(value, color):
    return f"{COLORS[color]}{value}{COLORS['reset']}" if use_color else value

def clean_id(target):
    value = str(target.get("id") or "unknown")
    return re.sub(r"^(guest:|host:|external:)", "", value)

def label(target):
    kind = str(target.get("type") or "external").lower()
    identifier = clean_id(target)
    name = str(target.get("name") or "").strip()
    if kind == "host":
        hostname = target.get('node') or name or identifier
        return f"{paint('Host', 'cyan')} : {paint(hostname, 'green')}"
    prefix = {"lxc": "LXC", "vm": "VM", "external": "External"}.get(kind, kind.title())
    target_label = f"{prefix} {identifier}"
    if name and name != identifier:
        target_label += f" : {name}"
    return paint(target_label, "green")

def integer(target, field):
    value = target.get(field)
    return str(value) if isinstance(value, int) and not isinstance(value, bool) else "Unknown"

def positive_updates(target):
    split = "normal_updates" in target or "security_updates" in target
    if split:
        return any(isinstance(target.get(field), int) and
                   not isinstance(target.get(field), bool) and target.get(field) > 0
                   for field in ("normal_updates", "security_updates"))
    values = target.get("updates")
    available = values.get("available") if isinstance(values, dict) else None
    return isinstance(available, int) and not isinstance(available, bool) and available > 0

def natural_key(value):
    return [int(part) if part.isdigit() else part.casefold()
            for part in re.split(r"(\d+)", str(value))]

def target_node(target):
    return str(target.get("node") or "").strip()

def target_sort_key(target):
    identifier = clean_id(target)
    numeric = int(identifier) if identifier.isdigit() else None
    return (numeric is None, numeric if numeric is not None else natural_key(identifier),
            str(target.get("name") or "").casefold(), identifier.casefold())

checked_targets = [
    target for target in targets
    if isinstance(target, dict) and
    target.get("check_status") in ("ok", "updates_available") and
    target.get("reachable") is True
]

node_targets = {}
external_targets = []
for target in checked_targets:
    kind = str(target.get("type") or "external").lower()
    if kind == "external":
        if positive_updates(target):
            external_targets.append(target)
    elif positive_updates(target):
        node_targets.setdefault(target_node(target) or "Unassigned", []).append(target)

# A checked host with no own updates still heads a node block when one of its
# guests has updates. It contributes no fabricated count of its own.
for target in checked_targets:
    if str(target.get("type") or "").lower() == "host":
        node = target_node(target) or "Unassigned"
        if node in node_targets and not positive_updates(target):
            node_targets[node].append(target)

def metric(target, field, prefix):
    return f"{prefix}:{integer(target, field)}"

def compact_name(target, width):
    name = str(target.get("name") or clean_id(target))
    if len(name) <= width:
        return name
    if width < 4:
        return name[:width]
    return name[:width - 3] + "..."

def guest_line(target, name_width, id_width):
    identifier = clean_id(target)
    name = compact_name(target, name_width)
    prefix = f"  {identifier:<{id_width}} {name:<{name_width}}"
    if "normal_updates" in target or "security_updates" in target:
        security = paint(metric(target, "security_updates", "S"), "orange")
        normal = metric(target, "normal_updates", "N")
        line = f"{prefix} {security} {normal}"
    else:
        values = target.get("updates")
        available = values.get("available") if isinstance(values, dict) else None
        value = str(available) if isinstance(available, int) and not isinstance(available, bool) else "Unknown"
        line = f"{prefix} Updates:{value}"
    if target.get("reboot_required") is True:
        line += f"  {paint('Reboot', 'orange')}"
    return paint(line[:len(prefix)], "green") + line[len(prefix):]

def host_header(node, host):
    header = paint(node, "cyan")
    if host is not None and positive_updates(host):
        if "normal_updates" in host or "security_updates" in host:
            header += f"  {paint(metric(host, 'security_updates', 'S'), 'orange')} {metric(host, 'normal_updates', 'N')}"
        else:
            values = host.get("updates")
            available = values.get("available") if isinstance(values, dict) else None
            if isinstance(available, int) and not isinstance(available, bool):
                header += f"  Updates:{available}"
    return header

rendered_nodes = []
for node in sorted(node_targets, key=natural_key):
    targets_for_node = sorted(node_targets[node],
                              key=lambda target: (target.get("type") != "host",
                                                  target_sort_key(target)))
    host = next((target for target in targets_for_node
                 if str(target.get("type") or "").lower() == "host"), None)
    guests = [target for target in targets_for_node if target is not host]
    rendered_nodes.append((node, host, guests))

name_width = min(24, max(
    [len(str(target.get("name") or clean_id(target)))
     for _, _, guests in rendered_nodes for target in guests] or [0]
))
id_width = max([len(clean_id(target)) for _, _, guests in rendered_nodes for target in guests] or [1])

for block_index, (node, host, guests) in enumerate(rendered_nodes):
    if block_index:
        print()
    print(host_header(node, host))
    for target in guests:
        print(guest_line(target, name_width, id_width))

if external_targets:
    if rendered_nodes:
        print()
    print(paint("External", "cyan"))
    external_width = min(24, max(len(str(target.get("name") or clean_id(target)))
                             for target in external_targets))
    external_id_width = max(len(clean_id(target)) for target in external_targets)
    for target in sorted(external_targets,
                         key=lambda item: (str(item.get("name") or "").casefold(),
                                            clean_id(item).casefold())):
        print(guest_line(target, external_width, external_id_width))
PY
}

# Convert the existing plain-text notification body into a small, safe HTML
# document immediately before delivery.  The text renderer remains the source
# of truth for notification content and selection; this helper only changes
# the wire representation for mail clients that collapse plain-text newlines.
# The conversion is based on the HTML mail formatting contributed by Negalein
# in the Ultimate Updater ioBroker forum thread.
STATUS_MODEL_SEND_HTML_MAIL() {
  local subject="${1:-}" sender="${2:-}" recipient="${3:-}"

  # mail(1) receives these values as headers.  Reject line breaks rather than
  # allowing configuration data to become additional mail headers.
  if [[ "$subject" == *$'\r'* || "$subject" == *$'\n'* ||
    "$sender" == *$'\r'* || "$sender" == *$'\n'* ||
    "$recipient" == *$'\r'* || "$recipient" == *$'\n'* ]]; then
    return 2
  fi

  python3 -c '
import html
import sys

body = sys.stdin.read()
lines = body.splitlines()
if not lines:
    lines = [""]

print("<!doctype html><html><body style=\"font-family:Arial,sans-serif;font-size:11pt;white-space:pre-wrap;overflow-wrap:anywhere\">")
for line in lines:
    content = html.escape(line) if line else "&nbsp;"
    print(f"<div style=\"margin:0;line-height:1.35;white-space:pre-wrap;overflow-wrap:anywhere\">{content}</div>")
print("</body></html>")
' | mail \
    -a 'Content-Type: text/html; charset=UTF-8' \
    -a 'Content-Transfer-Encoding: 8bit' \
    -r "$sender" \
    -s "$subject" \
    "$recipient"
}

# Render and optionally send one notification from the unified status model.
# The first output line is an internal decision marker; callers remove it
# before writing the human-readable mail body.
STATUS_MODEL_SEND_NOTIFICATION() {
  local status_file="${1:-${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}}"
  local config_file="${2:-${LOCAL_FILES:-/etc/ultimate-updater}/update.conf}"
  local email_user email_sender email_no_updates email_only_security email_daily_check email_single_runs

  email_user=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$config_file" 2>/dev/null)
  email_sender=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' "$config_file" 2>/dev/null)
  email_no_updates=$(awk -F'"' '/^EMAIL_NO_UPDATES=/ {print $2}' "$config_file" 2>/dev/null)
  email_daily_check=$(awk -F'"' '/^EMAIL_DAILY_CHECK=/ {print $2}' "$config_file" 2>/dev/null)
  email_only_security=$(awk -F'"' '/^EMAIL_ONLY_SECURITY=/ {print $2}' "$config_file" 2>/dev/null)
  email_single_runs=$(awk -F'"' '/^EMAIL_SINGLE_RUNS=/ {print $2}' "$config_file" 2>/dev/null)
  email_user="${email_user:-root}"
  email_sender="${email_sender:-$USER}"
  email_sender=$(STATUS_MODEL_EXPAND_SENDER "$email_sender")
  email_no_updates="${email_no_updates:-false}"
  email_daily_check="${email_daily_check:-true}"
  email_only_security="${email_only_security:-false}"
  email_single_runs="${email_single_runs:-false}"

  # Scheduler units mark their invocation explicitly.  This gate applies only
  # to scheduled checks; manual global checks and updates remain independent.
  # Keep it before the single-target policy so a scheduled selected-target
  # check is governed by EMAIL_DAILY_CHECK rather than the manual-run switch.
  if [[ ( "${UU_JOB_SOURCE:-}" == scheduler || "${UU_SCHEDULED_CHECK:-false}" == true ) && "$email_daily_check" != true ]]; then
    return 0
  fi

  local render_target="" render_kind=""
  if [[ "${UU_SINGLE_TARGET:-false}" == true ]]; then
    if [[ "${UU_JOB_SOURCE:-}" != scheduler && "${UU_SCHEDULED_CHECK:-false}" != true ]]; then
      [[ "$email_single_runs" == true ]] || return 0
    fi
    render_target="${UU_SINGLE_TARGET_ID:-}"
    render_kind="${UU_SINGLE_TARGET_KIND:-target}"
  fi

  local notification state body
  notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$status_file" check "$render_target" "$render_kind") || return 1
  state=${notification%%$'\n'*}
  state=${state#STATE=}
  body=${notification#*$'\n'}

  if [[ "$email_only_security" == true ]]; then
    if ! STATUS_MODEL_HAS_SECURITY_UPDATES "$status_file" "$render_target" "$render_kind"; then
      return 0
    fi
  fi

  case "$state" in
    updates|issues)
      printf '%s\n' "$body" |
        STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater summary - $HOSTNAME" "$email_sender" "$email_user" || true
      ;;
    current)
      if [[ "$email_no_updates" == true ]]; then
        printf '%s\n' "No updates found during search" |
          STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater" "$email_sender" "$email_user" || true
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
  local run_started_at="${3:-}"
  local email_user email_sender email_only_error email_single_runs notification state body

  email_user=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$config_file" 2>/dev/null)
  email_sender=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' "$config_file" 2>/dev/null)
  email_only_error=$(awk -F'"' '/^EMAIL_ONLY_ERROR=/ {print $2}' "$config_file" 2>/dev/null)
  email_single_runs=$(awk -F'"' '/^EMAIL_SINGLE_RUNS=/ {print $2}' "$config_file" 2>/dev/null)
  email_user="${email_user:-root}"
  email_sender="${email_sender:-${USER:-root}}"
  email_sender=$(STATUS_MODEL_EXPAND_SENDER "$email_sender")
  email_only_error="${email_only_error:-false}"
  email_single_runs="${email_single_runs:-false}"

  local render_target="" render_kind=""
  if [[ "${UU_SINGLE_TARGET:-false}" == true ]]; then
    [[ "$email_single_runs" == true ]] || return 0
    render_target="${UU_SINGLE_TARGET_ID:-}"
    render_kind="${UU_SINGLE_TARGET_KIND:-target}"
  fi

  notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$status_file" update "$render_target" "$render_kind" "$run_started_at") || return 1
  state=${notification%%$'\n'*}
  state=${state#STATE=}
  body=${notification#*$'\n'}

  [[ "$email_only_error" == true && "$state" != issues ]] && return 0
  printf '%s\n' "$body" |
    STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater summary - $HOSTNAME" "$email_sender" "$email_user" || true
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
  local scope_target="${3:-}"
  local scope_kind="${4:-}"
  local run_started_at="${5:-}"
  case "$run_type" in
    check|update) ;;
    *) return 2 ;;
  esac
  python3 - "$status_file" "$run_type" "$scope_target" "$scope_kind" "$run_started_at" <<'PY'
import json
import sys
from datetime import datetime

status_file, run_type, scope_target, scope_kind, run_started_at = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (OSError, ValueError):
    raise SystemExit(1)

targets = payload.get("targets")
if not isinstance(targets, list):
    raise SystemExit(1)

def parse_timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    # A run boundary without timezone information cannot safely distinguish
    # current results from historical records.
    return parsed if parsed.tzinfo is not None else None

run_scope_requested = bool(run_started_at)
started = parse_timestamp(run_started_at)

def current_update_result(target):
    if run_type != "update" or not run_scope_requested:
        return True
    if started is None:
        return False
    result = target.get("last_update")
    timestamp = result.get("timestamp") if isinstance(result, dict) else None
    if not timestamp:
        return False
    result_time = parse_timestamp(timestamp)
    if result_time is None:
        return False
    try:
        return result_time >= started
    except TypeError:
        return False

def target_matches_scope(target):
    if not scope_target:
        return True
    target_id = str(target.get("id") or "")
    wanted = str(scope_target)
    if scope_kind == "node":
        if target.get("type") != "host":
            return False
        candidates = {
            wanted,
            wanted.removeprefix("host:"),
            wanted.removeprefix("node-"),
        }
        values = {
            target_id,
            target_id.removeprefix("host:"),
            str(target.get("node") or ""),
            str(target.get("name") or ""),
        }
        # A local node action uses the sentinel "host".  The status model
        # contains one host record for that scoped check/update.
        return bool(candidates & values) or wanted == "host"
    candidates = {
        wanted,
        wanted.removeprefix("guest:"),
        wanted.removeprefix("host:"),
    }
    values = {
        target_id,
        target_id.removeprefix("guest:"),
        target_id.removeprefix("host:"),
    }
    return bool(candidates & values)

targets = [target for target in targets if isinstance(target, dict) and target_matches_scope(target)]
if scope_target and not targets:
    raise SystemExit(1)

updates = []
current = []
offline = []
unsupported = []
errors = []
not_checked = []
skipped = []
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
    elif target_id.startswith("external:"):
        target_id = target_id[9:]
    return f"{target_id} · {value}" if value and value != target_id else target_id

def target_icon(target):
    target_type = target.get("type")
    if target_type == "host":
        return "🖥️"
    if target_type == "external":
        return "🌐"
    if target_type == "lxc":
        return "🐧"
    if target_type != "vm":
        return "🌐"

    # Do not infer Linux merely because a VM has no successful OS probe.  A
    # Windows updater or Windows Update Agent record is authoritative enough
    # to retain the Windows icon even when the latest OS text is unavailable.
    os_values = (
        target.get("os"),
        target.get("os_version"),
        target.get("os_display"),
        target.get("os_detail_display"),
    )
    os_text = " ".join(str(value) for value in os_values if value).lower()
    windows_update = target.get("windows_update")
    windows_source = (
        str(windows_update.get("source") or "").lower()
        if isinstance(windows_update, dict) else ""
    )
    updater = str(target.get("updater") or "").lower()
    if "windows" in os_text or updater == "windows-update" or "windows update agent" in windows_source:
        return "🪟"

    # Existing non-Windows VM icon rules remain unchanged when a Unix-like OS
    # or package updater is known.  An otherwise unclassified VM is neutral.
    known_linux_updaters = {"apt", "dnf", "pkg", "pacman", "apk", "yum", "ha"}
    known_os_markers = (
        "linux", "debian", "ubuntu", "freebsd", "pfsense", "fedora",
        "centos", "rhel", "rocky", "alma", "opensuse", "suse", "arch",
        "alpine", "gentoo", "home assistant", "haos",
    )
    known_os = any(marker in os_text for marker in known_os_markers)
    if known_os or updater in known_linux_updaters:
        return "🐧"
    return "❔"

def short_error(target):
    error = target.get("error")
    if isinstance(error, dict):
        message = error.get("message") or error.get("code")
        if message:
            return str(message).replace("\n", " ").strip()
    return "check failed"

def check_skip_message(target):
    """Return neutral wording for checks intentionally not executed."""
    status = str(target.get("check_status") or "not_checked")
    skip_reason = target.get("skip_reason")
    code = str(skip_reason.get("code") or "") if isinstance(skip_reason, dict) else ""
    if not code:
        # Legacy status files may have carried a neutral code in error.  Keep
        # their notification wording compatible without treating real errors
        # as skips.
        error = target.get("error")
        code = str(error.get("code") or "") if isinstance(error, dict) else ""
    if status not in ("not_checked", "skipped", "stopped"):
        return None
    if code in {"RUNNING_DISABLED", "CHECK_WITH_HOST_DISABLED", "CHECK_DISABLED"}:
        return "Check disabled"
    if code in {"STOPPED_READ_ONLY", "PAUSED_READ_ONLY", "UNSUPPORTED_GUEST_OS", "NO_SUPPORTED_TRANSPORT"}:
        return "Skipped by configuration"
    return None

def update_split(target):
    if target.get("security_split_supported") is False or \
       ("security_split_supported" not in target and target.get("updater") != "apt" and
        "normal_updates" not in target and "security_updates" not in target):
        values = target.get("updates")
        available = values.get("available") if isinstance(values, dict) else None
        return [f"Updates: {available if isinstance(available, int) else 'Unknown'}"]
    def value(name):
        candidate = target.get(name)
        if isinstance(candidate, int) and not isinstance(candidate, bool):
            return str(candidate)
        return "Unknown"
    return [
        f"Security Updates: {value('security_updates')}",
        f"Normal Updates: {value('normal_updates')}",
    ]

def update_result(target):
    result = target.get("last_update")
    return result if isinstance(result, dict) else {}

def update_result_has_evidence(target, result):
    pending_before = result.get("pending_before")
    if isinstance(pending_before, bool) or not isinstance(pending_before, int):
        # A result without the update's explicit baseline is not evidence of
        # a package mutation, even when a backend reports processed packages.
        return False
    updated_packages = result.get("updated_packages")
    if isinstance(updated_packages, bool) or not isinstance(updated_packages, int):
        updated_packages = None
    processed = result.get("processed")
    if isinstance(processed, bool) or not isinstance(processed, int):
        processed = None

    if pending_before < 0:
        return False
    if pending_before == 0:
        values = target.get("updates")
        available = values.get("available") if isinstance(values, dict) else None
        return target.get("check_status") in ("ok", "updates_available") and \
               isinstance(available, int) and not isinstance(available, bool) and available == 0
    if updated_packages is not None:
        return updated_packages > 0
    if processed is not None:
        return processed > 0
    # A positive pre-update count is sufficient evidence for the legacy
    # backends that do not report a post-update package count.
    return True

def update_status(target):
    if not current_update_result(target):
        return "unknown"
    result = update_result(target)
    status = str(result.get("status") or "").lower()
    if status in ("failed", "interrupted"):
        return "failed"
    if status in ("skipped", "no-op", "no_op"):
        return "skipped"
    if status == "unsupported":
        return "unsupported"
    if status == "completed_with_warnings":
        return "warning" if update_result_has_evidence(target, result) else "unknown"
    if status in ("success", "completed"):
        return "success" if update_result_has_evidence(target, result) else "unknown"
    return "unknown"

def update_line(target):
    result = update_result(target)
    if target.get("check_status") == "offline" or target.get("reachable") is False:
        return "⚠️", "Not reachable"
    status = update_status(target)
    if status == "warning":
        return "⚠️", "Update completed with warnings"
    if status == "failed":
        return "❌", "Update failed"
    if status == "unsupported":
        return "💤", "Update unsupported"
    if status == "success" and not update_result_has_evidence(target, result):
        return "⚠️", "Result unavailable"
    skipped = check_skip_message(target)
    if skipped is not None:
        return "💤", skipped
    if status == "skipped":
        if result.get("pending_before") == 0:
            return "💤", "No updates available"
        return "💤", "Update skipped"
    if status != "success":
        return "⚠️", "Result unavailable"
    if target.get("reboot_required") is True:
        return "⚠️", "Updated – reboot required"
    pending_before = result.get("pending_before")
    if isinstance(pending_before, int) and not isinstance(pending_before, bool):
        if pending_before == 0:
            return "✅", "Up to date"
        updated = result.get("updated_packages")
        if isinstance(updated, int) and not isinstance(updated, bool) and updated >= 0:
            return "✅", f"{updated} packages updated"
        return "✅", "Successfully updated"
    updated = result.get("updated_packages")
    if isinstance(updated, int) and not isinstance(updated, bool) and updated >= 0:
        return "✅", f"{updated} packages updated"
    return "✅", "Successfully updated"

if run_type == "update":
    hosts = []
    guest_success = []
    guest_failed = []
    guest_offline = []
    guest_reboot = []
    guest_skipped = []
    guest_warning = []
    guest_unavailable = []
    for target in targets:
        if not isinstance(target, dict):
            continue
        is_host = target.get("type") == "host" or str(target.get("id") or "").startswith("host:")
        status = target.get("check_status") or "not_checked"
        reachable = target.get("reachable")
        if is_host:
            hosts.append(target)
            continue
        skip_message = check_skip_message(target)
        if skip_message is not None:
            guest_skipped.append(target)
            continue
        if status == "offline" or reachable is False:
            guest_offline.append(target)
            continue
        result_status = update_status(target)
        if result_status == "warning":
            guest_warning.append(target)
        elif result_status == "unknown":
            guest_unavailable.append(target)
        elif result_status == "skipped":
            guest_skipped.append(target)
        elif result_status == "unsupported":
            guest_skipped.append(target)
        elif result_status == "failed":
            guest_failed.append(target)
        elif result_status == "success":
            values = target.get("updates")
            available = values.get("available") if isinstance(values, dict) else None
            if target.get("reboot_required") is True:
                guest_reboot.append(target)
            elif isinstance(available, int) and not isinstance(available, bool) and available == 0:
                guest_success.append(target)
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
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", "   Updated – reboot required"])
    if guest_failed:
        lines.extend(["", "Failed guests:"])
        for target in guest_failed:
            _, message = update_line(target)
            lines.extend([f"❌ {target_icon(target)} {target_name(target)}", f"   {message}"])
    if guest_offline:
        lines.extend(["", "Unreachable guests:"])
        for target in guest_offline:
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", "   Not reachable"])
    if guest_skipped:
        lines.extend(["", "Skipped checks:"])
        for target in guest_skipped:
            _, skipped_message = update_line(target)
            lines.extend([f"💤 {target_icon(target)} {target_name(target)}", f"   {skipped_message}"])
    if guest_warning:
        lines.extend(["", "Update warnings:"])
        for target in guest_warning:
            _, warning_message = update_line(target)
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", f"   {warning_message}"])
    if guest_unavailable:
        lines.extend(["", "Results unavailable:"])
        for target in guest_unavailable:
            _, unavailable_message = update_line(target)
            lines.extend([f"⚠️ {target_icon(target)} {target_name(target)}", f"   {unavailable_message}"])
    print("STATE=issues" if any(update_status(target) == "failed" for target in hosts + guest_failed) or
          guest_offline or guest_warning or guest_unavailable else "STATE=updates")
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

    skip_message = check_skip_message(target)
    if skip_message is not None:
        skipped.append(target)
    elif status == "offline" or reachable is False:
        offline.append(target)
    elif status == "unsupported":
        unsupported.append(target)
    elif status == "error":
        errors.append((target, short_error(target)))
    elif status in ("not_checked", "skipped", "stopped"):
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
    separator = "----------------------------"
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
    for node_index, node in enumerate(node_order):
        node_targets = grouped[node]
        node_target = next((target for target, _ in node_targets if target.get("type") == "host"), None)
        # Keep the existing section spacing before the first node and add one
        # blank line only when moving to the next node group. Targets within
        # one node remain a compact block separated by their existing rules.
        lines.append("")
        if node_target is not None:
            lines.append(f"🖥️ {node}")
            lines.extend(update_split(node_target))
            lines.append(separator)
        else:
            lines.extend([f"🖥️ {node}", f"⬆️ {sum(count for _, count in node_targets)} Updates", separator])
        guest_targets = [(target, count) for target, count in node_targets if target.get("type") != "host"]
        for target, _ in guest_targets:
            # The node heading already represents a host target. Do not
            # render the same host a second time as a guest-like row.
            lines.append(f"{target_icon(target)} {target_name(target)}")
            lines.extend(update_split(target))
            if target.get("reboot_required") is True:
                lines.append("🔄 Reboot required")
            lines.append(separator)
else:
    lines.append("Available updates: none")
if has_known_count:
    lines.extend(["", f"Total available updates: {total}"])
if current:
    lines.extend(["", "Current:"])
    for target in current:
        lines.extend([f"✅ {target_icon(target)} {target_name(target)}", "   No updates available"])
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
if skipped:
    lines.extend(["", "Skipped:"])
    for target in skipped:
        lines.extend([f"💤 {target_name(target)}", f"   {check_skip_message(target)}"])

print(f"STATE={state}")
print("\n".join(lines))
PY
}
