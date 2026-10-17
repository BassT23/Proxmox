#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

write_status() {
  python3 - "$1" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "targets": [{
    "id": "910", "type": "lxc", "check_status": "error",
    "error": {"code": "CHECK_COMMAND_FAILED", "message": "old failure"},
    "last_update": {"status": "unknown", "timestamp": None},
}, {
    "id": "keep", "type": "vm", "check_status": "ok", "error": None,
    "skip_reason": None,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
}

run_record() {
  local status_file="$1" records_file="$2" record="$3"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$status_file" \
    STATUS_MODEL_RECORD_FILE="$records_file" STATUS_MODEL_PARTIAL=true bash -c '
      source "$1"
      STATUS_MODEL_INIT
      eval "$2"
      STATUS_MODEL_FINISH
    ' _ "$ROOT_DIR/status-model.sh" "$record"
}

STATUS_FILE="$WORK_DIR/status.json"
write_status "$STATUS_FILE"
run_record "$STATUS_FILE" "$WORK_DIR/stopped.records" \
  'STATUS_MODEL_RECORD 910 lxc pct false "" "" null null not_checked STOPPED_READ_ONLY "LXC 910 is stopped; the check did not start it" node1 lxc-910'

python3 - "$STATUS_FILE" <<'PY'
import json
import sys

targets = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
stopped = targets["910"]
assert stopped["check_status"] == "not_checked"
assert stopped["error"] is None
assert stopped["skip_reason"] == {
    "code": "STOPPED_READ_ONLY",
    "message": "LXC 910 is stopped; the check did not start it",
}
assert targets["keep"]["check_status"] == "ok"
PY

run_record "$STATUS_FILE" "$WORK_DIR/paused.records" \
  'STATUS_MODEL_RECORD 910 vm qga false "" "" null null not_checked PAUSED_READ_ONLY "VM 910 is paused; the check did not resume it" node1 vm-910'
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["error"] is None
assert target["skip_reason"]["code"] == "PAUSED_READ_ONLY"
PY

run_record "$STATUS_FILE" "$WORK_DIR/success.records" \
  'STATUS_MODEL_RECORD 910 lxc pct true Debian apt 0 false ok "" "" node1 lxc-910 0 0'
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["check_status"] == "ok"
assert target["error"] is None
assert target["skip_reason"] is None
PY

run_record "$STATUS_FILE" "$WORK_DIR/error.records" \
  'STATUS_MODEL_RECORD 910 lxc pct true Debian apt null null error CHECK_COMMAND_FAILED "apt failed" node1 lxc-910'
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["check_status"] == "error"
assert target["error"]["code"] == "CHECK_COMMAND_FAILED"
assert target["skip_reason"] is None
PY

# A skip replaces a previous error and a later successful check removes it.
run_record "$STATUS_FILE" "$WORK_DIR/skip-again.records" \
  'STATUS_MODEL_RECORD 910 lxc pct false "" "" null null not_checked RUNNING_DISABLED "configured check disabled" node1 lxc-910'
python3 - "$STATUS_FILE" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["error"] is None
assert target["skip_reason"]["code"] == "RUNNING_DISABLED"
PY

# STATUS_MODEL_UPSERT uses the same neutral/error distinction.
STATUS_MODEL_FILE="$WORK_DIR/upsert.json" LOCAL_FILES="$WORK_DIR" bash -c '
  source "$1"
  STATUS_MODEL_UPSERT 912 vm qga false "" "" qga null null not_checked CHECK_DISABLED "configured off"
' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/upsert.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["error"] is None
assert target["skip_reason"]["code"] == "CHECK_DISABLED"
PY

# Remote import preserves skip_reason together with last_update and WUA data.
python3 - "$WORK_DIR/remote.json" <<'PY'
import json
import sys

json.dump({"targets": [{
    "id": "910", "type": "lxc", "transport": "pct", "reachable": False,
    "check_status": "not_checked", "error": None,
    "skip_reason": {"code": "STOPPED_READ_ONLY", "message": "stopped"},
    "last_update": {"status": "success", "timestamp": "2026-10-17T12:00:00Z", "exit_code": 0},
    "windows_update": {"source": "Windows Update Agent", "history": [{"title": "fixture"}]},
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/remote-status.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/remote.records" \
  STATUS_MODEL_PARTIAL=false LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_IMPORT_FILE "$2"
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/remote.json"
python3 - "$WORK_DIR/remote-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["error"] is None
assert target["skip_reason"]["code"] == "STOPPED_READ_ONLY"
assert target["last_update"]["status"] == "success"
assert target["windows_update"]["history"][0]["title"] == "fixture"
PY

# A history-only refresh must not mutate the existing check observation.  This
# covers nested records as well as the fields explicitly preserved by the
# history-only merge.
python3 - "$WORK_DIR/history-status.json" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "targets": [{
    "id": "910", "name": "original-lxc", "type": "lxc", "transport": "pct",
    "reachable": True, "os": "Debian 12", "os_version": "12", "updater": "apt",
    "updates": {"available": 9}, "normal_updates": 7, "security_updates": 2,
    "security_split_supported": True, "reboot_required": False,
    "check_status": "not_checked", "last_check": "2026-10-17T12:00:00Z",
    "error": None, "skip_reason": {"code": "STOPPED_READ_ONLY", "message": "stopped"},
    "node": "node1",
    "last_update": {"status": "success", "timestamp": "2026-10-17T11:00:00Z"},
    "windows_update": {"source": "Windows Update Agent", "queried_at": "2026-10-17T11:00:00Z",
                        "history": [{"title": "old history"}]},
}, {
    "id": "keep", "name": "untouched", "type": "vm", "check_status": "ok",
    "updates": {"available": 3}, "last_check": "2026-10-17T11:30:00Z",
    "error": None, "skip_reason": None,
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
cp "$WORK_DIR/history-status.json" "$WORK_DIR/history-before.json"
HISTORY_PAYLOAD='{"source":"Windows Update Agent","queried_at":"2026-10-17T12:05:00Z","history":[{"title":"new history"}]}'
HISTORY_RECORD=$(printf 'STATUS_MODEL_RECORD 910 lxc pct true Debian apt null null history_only "" "" node1 history-lxc 7 2 %q' "$HISTORY_PAYLOAD")
run_record "$WORK_DIR/history-status.json" "$WORK_DIR/history.records" "$HISTORY_RECORD"
python3 - "$WORK_DIR/history-before.json" "$WORK_DIR/history-status.json" <<'PY'
import json
import sys

before = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
after = {item["id"]: item for item in json.load(open(sys.argv[2], encoding="utf-8"))["targets"]}
target = after["910"]
assert after["keep"] == before["keep"]
assert target["name"] == "original-lxc"
assert target["check_status"] == "not_checked"
assert target["last_check"] == "2026-10-17T12:00:00Z"
assert target["error"] is None
assert target["skip_reason"] == before["910"]["skip_reason"]
assert target["reachable"] is True
assert target["updates"] == {"available": 9}
assert target["normal_updates"] == 7
assert target["security_updates"] == 2
assert target["security_split_supported"] is True
assert target["reboot_required"] is False
assert target["os"] == "Debian 12"
assert target["os_version"] == "12"
assert target["updater"] == "apt"
assert target["transport"] == "pct"
assert target["type"] == "lxc"
assert target["node"] == "node1"
assert target["last_update"] == before["910"]["last_update"]
assert target["windows_update"]["history"] == [{"title": "new history"}]
PY

# The same preservation contract applies when the previous observation was a
# real error or a successful check.
python3 - "$WORK_DIR/history-before.json" "$WORK_DIR/history-error.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if item["id"] == "910")
target["check_status"] = "error"
target["error"] = {"code": "CHECK_COMMAND_FAILED", "message": "old error"}
target["skip_reason"] = None
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"))
PY
run_record "$WORK_DIR/history-error.json" "$WORK_DIR/history-error.records" "$HISTORY_RECORD"
python3 - "$WORK_DIR/history-error.json" <<'PY'
import json
import sys

target = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if item["id"] == "910")
assert target["check_status"] == "error"
assert target["error"] == {"code": "CHECK_COMMAND_FAILED", "message": "old error"}
assert target["skip_reason"] is None
assert target["last_check"] == "2026-10-17T12:00:00Z"
PY

python3 - "$WORK_DIR/history-before.json" "$WORK_DIR/history-success.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if item["id"] == "910")
target["check_status"] = "ok"
target["error"] = None
target["skip_reason"] = None
json.dump(payload, open(sys.argv[2], "w", encoding="utf-8"))
PY
run_record "$WORK_DIR/history-success.json" "$WORK_DIR/history-success.records" "$HISTORY_RECORD"
cp "$WORK_DIR/history-success.json" "$WORK_DIR/history-repeat-before.json"
run_record "$WORK_DIR/history-success.json" "$WORK_DIR/history-repeat.records" "$HISTORY_RECORD"
python3 - "$WORK_DIR/history-success.json" "$WORK_DIR/history-repeat-before.json" <<'PY'
import json
import sys

after = {item["id"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]}
before = {item["id"]: item for item in json.load(open(sys.argv[2], encoding="utf-8"))["targets"]}
assert after["910"] == before["910"]
assert after["keep"] == before["keep"]
PY

# Old status files without the optional field remain readable.
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "targets": [{"id": "legacy", "type": "lxc",
    "check_status": "ok", "error": None}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_FILE="$WORK_DIR/legacy.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/legacy.records" \
  STATUS_MODEL_PARTIAL=true LOCAL_FILES="$WORK_DIR" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["id"] == "legacy"
assert target.get("skip_reason") is None
PY

# Notification rendering recognizes skip_reason without rendering a failure.
cat > "$WORK_DIR/notification.json" <<'JSON'
{"targets":[{"id":"910","type":"lxc","name":"fixture","check_status":"not_checked","reachable":true,"updates":{"available":null},"error":null,"skip_reason":{"code":"STOPPED_READ_ONLY","message":"stopped"}}]}
JSON
LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2"' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/notification.json" > "$WORK_DIR/mail.txt"
grep -Fqx '   Skipped by configuration' "$WORK_DIR/mail.txt"
if grep -Fq 'check failed' "$WORK_DIR/mail.txt"; then
  echo "neutral skip was rendered as a failure" >&2
  exit 1
fi

printf '%s\n' 'status model skip-reason regression tests: PASS'
