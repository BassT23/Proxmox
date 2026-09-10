#!/bin/bash

# Optional Ultimate Updater-owned target selection.
# The legacy Proxmox tag filter remains authoritative unless the explicit
# config switch enables this file's rules.

TARGET_SELECTION_FILE="${UU_TARGET_SELECTION_FILE:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/target-selection.json}"

TARGET_SELECTION_ENABLED() {
  [[ "${USE_INTERNAL_TARGET_SELECTION:-false}" == true ]] || return 1
  [[ ! -e "$TARGET_SELECTION_FILE" ]] && return 0
  [[ -r "$TARGET_SELECTION_FILE" ]] || return 1
  python3 - "$TARGET_SELECTION_FILE" "${UU_FILTER_SCOPE:-update}" <<'PY'
import json
import sys

path, scope = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        data = json.load(source)
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(data, dict) and data.get("schema_version") == 1 and scope in {"check", "update"} else 1)
PY
}

TARGET_SELECTION_STATE() {
  local scope="$1" candidate_ids="${2:-}"
  TARGET_SELECTION_ENABLED || return 1
  python3 - "$TARGET_SELECTION_FILE" "$scope" "$candidate_ids" <<'PY'
import json
import sys

path, scope, raw_ids = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        data = json.load(source)
except FileNotFoundError:
    data = {"schema_version": 1}
except (OSError, ValueError, TypeError):
    raise SystemExit(1)
rules = data.get(scope, {}) if isinstance(data, dict) else {}
if not isinstance(rules, dict):
    rules = {}
ids = [item for item in raw_ids.split() if item]
valid = {item for item in ids if isinstance(item, str) and item}
configured_only = {key for key, value in rules.items() if value == "only"}
only = configured_only & valid
exclude = {key for key, value in rules.items() if key in valid and value == "exclude"}
selected = (only if configured_only else valid) - exclude
print(" ".join(item for item in ids if item in selected))
PY
}

TARGET_SELECTION_ALLOWS() {
  local scope="$1" target_id="$2" selected
  local candidate_ids="${3:-$target_id}"
  [[ "${USE_INTERNAL_TARGET_SELECTION:-false}" == true ]] || return 0
  selected=$(TARGET_SELECTION_STATE "$scope" "$candidate_ids") || return 1
  [[ " $selected " == *" $target_id "* ]]
}

TARGET_SELECTION_WRITE() {
  local content="$1" directory temporary
  directory="${TARGET_SELECTION_FILE%/*}"
  [[ "$directory" != "$TARGET_SELECTION_FILE" ]] || directory=.
  mkdir -p -- "$directory" || return 1
  temporary=$(mktemp "$directory/.target-selection.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  chmod 600 "$temporary" || { rm -f -- "$temporary"; return 1; }
  if [[ "$(id -u)" -eq 0 ]]; then chown root:root "$temporary" || { rm -f -- "$temporary"; return 1; }; fi
  mv -f -- "$temporary" "$TARGET_SELECTION_FILE"
}
