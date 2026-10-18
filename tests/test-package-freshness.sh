#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

run_record() {
  local status_file="$1" record_file="$2" record="$3"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$status_file" \
    STATUS_MODEL_RECORD_FILE="$record_file" STATUS_MODEL_PARTIAL=true bash -c '
      source "$1"
      STATUS_MODEL_INIT
      STATUS_MODEL_CAPTURE_TARGET_GENERATION 910 || true
      eval "$2"
      STATUS_MODEL_FINISH
    ' _ "$ROOT_DIR/status-model.sh" "$record"
}

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"910","type":"lxc","node":"node1","package_mutation_generation":0,"package_mutation_in_progress":false,"package_data_invalidated":false,"reachable":true,"updater":"apt","updates":{"available":4},
   "check_status":"ok","last_check":"2026-10-17T10:00:00Z",
   "package_checked_at":"2026-10-17T10:00:00Z","error":null,"skip_reason":null,
   "last_update":{"status":"unknown","timestamp":null}},
  {"id":"keep","type":"vm","node":"node1","package_mutation_generation":0,"package_mutation_in_progress":false,"package_data_invalidated":false,"reachable":true,"updater":"apt","updates":{"available":2},
   "check_status":"ok","last_check":"2026-10-17T09:00:00Z",
   "package_checked_at":"2026-10-17T09:00:00Z","error":null,"skip_reason":null}
]}
JSON

run_record "$WORK_DIR/status.json" "$WORK_DIR/skip.records" \
  'STATUS_MODEL_RECORD 910 lxc pct false "" "" null null not_checked STOPPED_READ_ONLY "stopped" node1 lxc-910'
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if item["id"] == "910")
assert target["check_status"] == "not_checked"
assert target["package_checked_at"] == "2026-10-17T10:00:00Z"
assert target["updates"] == {"available": 4}
PY

run_record "$WORK_DIR/status.json" "$WORK_DIR/failure.records" \
  'STATUS_MODEL_RECORD 910 lxc pct true Debian apt null null error CHECK_COMMAND_FAILED "failed" node1 lxc-910'
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["check_status"] == "error"
assert target["package_checked_at"] == "2026-10-17T10:00:00Z"
assert target["error"]["code"] == "CHECK_COMMAND_FAILED"
PY

run_record "$WORK_DIR/status.json" "$WORK_DIR/success.records" \
  'STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 0 0 "" now'
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["check_status"] == "ok"
assert target["package_checked_at"].endswith("Z")
assert target["updates"] == {"available": 0}
PY

# A valid-looking result without a captured mutation generation must fail
# closed; it must not turn legacy package data into a fresh observation.
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/no-generation.records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 0 0 "" now
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys
target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
PY

# History-only data may be imported repeatedly, but cannot change the latest
# package-check provenance or the other check metadata.
python3 - "$WORK_DIR/history.json" <<'PY'
import json
import sys

payload = {
    "targets": [{
        "id": "910", "type": "lxc", "transport": "pct", "reachable": True,
        "updater": "apt", "updates": {"available": 99}, "check_status": "history_only",
        "last_check": "2026-10-17T12:00:00Z",
        "package_checked_at": "2026-10-17T10:00:00Z",
        "last_update": {"status": "success", "timestamp": "2026-10-17T11:00:00Z"},
        "windows_update": {"source": "Windows Update Agent", "history": [{"title": "new"}]},
    }]
}
json.dump(payload, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/history-result.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/history.records" \
  STATUS_MODEL_PARTIAL=false LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/history.json"
python3 - "$WORK_DIR/history-result.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["check_status"] == "history_only"
assert target["last_check"] == "2026-10-17T12:00:00Z"
assert "package_checked_at" not in target
assert target["updates"] == {"available": 99}
assert target["windows_update"]["history"] == [{"title": "new"}]
PY

# A remote import carries source timestamps.  Missing source timestamps do
# not become the local import time.
python3 - "$WORK_DIR/remote.json" <<'PY'
import json
import sys

json.dump({"targets": [{
    "id": "remote", "type": "lxc", "reachable": True, "updater": "apt",
    "updates": {"available": 1}, "check_status": "ok",
    "last_check": "2026-10-17T08:00:00Z",
    "package_checked_at": "2026-10-17T08:00:00Z",
    "package_mutation_generation": 0,
    "package_mutation_in_progress": False,
    "package_data_invalidated": False,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/remote-result.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/remote.records" \
  STATUS_MODEL_PARTIAL=false LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/remote.json"
python3 - "$WORK_DIR/remote-result.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["last_check"] == "2026-10-17T08:00:00Z"
assert target["package_checked_at"] == "2026-10-17T08:00:00Z"
PY

# Mutation invalidation is target-scoped, atomic, and survives update results
# and old remote/history imports.  A later validated package check is the only
# operation in this fixture allowed to clear it.
cat > "$WORK_DIR/invalidation.json" <<'JSON'
{"schema_version":1,"generated_at":"2026-10-17T12:00:00Z","targets":[
  {"id":"910","type":"lxc","reachable":true,"updater":"apt",
   "updates":{"available":5},"check_status":"ok",
   "last_check":"2026-10-17T10:00:00Z",
   "node":"node1","package_mutation_generation":0,"package_mutation_in_progress":false,
   "package_checked_at":"2026-10-17T10:00:00Z",
   "package_data_invalidated":false,
   "last_update":{"status":"unknown","timestamp":null}},
  {"id":"keep","type":"lxc","reachable":true,"updater":"apt",
   "updates":{"available":2},"check_status":"ok",
   "last_check":"2026-10-17T09:00:00Z",
   "node":"node1","package_mutation_generation":0,"package_mutation_in_progress":false,
   "package_checked_at":"2026-10-17T09:00:00Z",
   "package_data_invalidated":false}
]}
JSON
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_INVALIDATE_PACKAGE_DATA 910 lxc node1
' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if item["id"] == "910")
keep = next(item for item in payload["targets"] if item["id"] == "keep")
assert target["package_data_invalidated"] is True
assert isinstance(target["package_data_invalidated_at"], str)
assert target["package_checked_at"] == "2026-10-17T10:00:00Z"
assert keep["package_data_invalidated"] is False
PY

STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_UPDATE_RESULT 910 failed 17
' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
assert target["package_checked_at"] == "2026-10-17T10:00:00Z"
assert target["last_update"]["status"] == "failed"
PY

python3 - "$WORK_DIR/old-history.json" <<'PY'
import json
import sys

json.dump({"targets": [{
    "id": "910", "type": "lxc", "reachable": True, "updater": "apt",
    "updates": {"available": 99}, "check_status": "history_only",
    "last_check": "2026-10-17T08:00:00Z",
    "package_checked_at": "2026-10-17T08:00:00Z",
    "package_data_invalidated": False,
    "last_update": {"status": "success", "timestamp": "2026-10-17T08:00:00Z"},
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/old-history.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/old-history.json"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
assert target["package_checked_at"] == "2026-10-17T10:00:00Z"
assert target["last_check"] == "2026-10-17T10:00:00Z"
assert target["updates"] == {"available": 5}
assert target["last_update"]["status"] == "failed"
PY

STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/valid-check.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_COMPLETE_PACKAGE_MUTATION 910 lxc node1
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION 910
    STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 null null "" now
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is False
assert "package_data_invalidated_at" not in target
assert target["package_checked_at"] != "2026-10-17T10:00:00Z"
assert target["updates"] == {"available": 0}
PY

# A failed invalidation must not create a new, unverified target record.
if STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_INVALIDATE_PACKAGE_DATA missing-target lxc node1
' _ "$ROOT_DIR/status-model.sh"; then
  echo 'unexpected invalidation of unknown target' >&2
  exit 1
fi
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert not any(item.get("id") == "missing-target" for item in payload["targets"])
PY

# An observation captured before a mutation cannot clear the newer generation.
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/race.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION 910
    STATUS_MODEL_INVALIDATE_PACKAGE_DATA 910 lxc node1
    STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 null null "" now
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys
target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
assert target["package_mutation_generation"] >= 1
PY

# A check that starts after invalidation but before the mutation is complete
# must not clear the reservation merely because the mutation later ends.
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/race-after-invalidation.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INVALIDATE_PACKAGE_DATA 910 lxc node1 uu-op-race-after-invalidation-20261017T120000
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION 910
    STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 null null "" now
    STATUS_MODEL_COMPLETE_PACKAGE_MUTATION 910 lxc node1 uu-op-race-after-invalidation-20261017T120000
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys
target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
assert target["package_mutation_in_progress"] is False
PY

# A fresh post-mutation capture uses the current generation and may clear it.
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/race-new.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_COMPLETE_PACKAGE_MUTATION 910 lxc node1
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION 910
    STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 null null "" now
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys
target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is False
assert target["package_mutation_in_progress"] is False
PY

# A remote error, including an explicit false marker, cannot clear a newer
# local invalidation.
python3 - "$WORK_DIR/remote-error.json" <<'PY'
import json
import sys
json.dump({"targets": [{
    "id": "910", "type": "lxc", "node": "node1", "reachable": True,
    "updater": "apt", "updates": {"available": None}, "check_status": "error",
    "error": {"code": "CHECK_COMMAND_FAILED", "message": "remote failed"},
    "last_check": "2026-10-17T12:00:00Z", "package_checked_at": "2026-10-17T10:00:00Z",
    "package_mutation_generation": 2, "package_mutation_in_progress": False,
    "package_data_invalidated": False,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/invalidation.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/remote-error.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INVALIDATE_PACKAGE_DATA 910 lxc node1
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/remote-error.json"
python3 - "$WORK_DIR/invalidation.json" <<'PY'
import json
import sys
target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["package_data_invalidated"] is True
PY

# Invalid target identity must not select a different record that reuses the
# same ID.
cp "$WORK_DIR/invalidation.json" "$WORK_DIR/identity.json"
if STATUS_MODEL_FILE="$WORK_DIR/identity.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_INVALIDATE_PACKAGE_DATA 910 external node1
' _ "$ROOT_DIR/status-model.sh"; then
  echo 'unexpected external/lxc identity invalidation' >&2
  exit 1
fi
python3 - "$WORK_DIR/identity.json" <<'PY'
import json
import sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if item["id"] == "910")
assert target["type"] == "lxc"
assert target["package_data_invalidated"] is True
PY

# A missing status model may be initialized only for the exact requested
# identity; a damaged model must fail closed.
rm -f "$WORK_DIR/missing.json"
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/missing.json" bash -c '
  source "$1"
  STATUS_MODEL_INVALIDATE_PACKAGE_DATA 700 external
' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/missing.json" <<'PY'
import json
import sys
target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["id"] == "700" and target["type"] == "external"
assert target["package_data_invalidated"] is True
PY
printf '{not-json\n' > "$WORK_DIR/corrupt.json"
if STATUS_MODEL_FILE="$WORK_DIR/corrupt.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_INVALIDATE_PACKAGE_DATA 700 external
' _ "$ROOT_DIR/status-model.sh"; then
  echo 'unexpected invalidation of corrupt status model' >&2
  exit 1
fi

# A legacy record without generation metadata is not fresh by inference, but
# a new validated local package check may establish the initial epoch safely.
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "targets": [{
    "id": "legacy-910", "type": "lxc", "node": "node1",
    "reachable": True, "updater": "apt", "updates": {"available": 3},
    "check_status": "ok", "last_check": "2026-10-16T10:00:00Z",
    "error": None, "skip_reason": None,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/legacy.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/legacy.records" STATUS_MODEL_PARTIAL=true bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION legacy-910
    STATUS_MODEL_RECORD legacy-910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 null null "" now
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["package_data_invalidated"] is False
assert target["package_mutation_generation"] == 0
assert isinstance(target["package_checked_at"], str)
PY

printf '%s\n' 'package freshness status-model tests: PASS'
