#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

grep -Fq 'GetTotalHistoryCount' "$ROOT_DIR/windows-update.sh"
grep -Fq 'QueryHistory' "$ROOT_DIR/windows-update.sh"
grep -Fq 'QueryHistory(0, $limit)' "$ROOT_DIR/windows-update.sh"
if grep -Fq 'KBArticleIDs' "$ROOT_DIR/windows-update.sh"; then
  echo 'history entries must not read KBArticleIDs from IUpdateHistoryEntry' >&2
  exit 1
fi
grep -Fq "source = 'Windows Update Agent'" "$ROOT_DIR/windows-update.sh"
history_action=$(sed -n '/    history)/,/    preflight)/p' "$ROOT_DIR/windows-update.sh")
if grep -Fq 'Download()' <<< "$history_action"; then
  echo 'history action must not download updates' >&2
  exit 1
fi

awk '
  /^CHECK_VM_QEMU_WINDOWS \(\) \{/ {copy=1}
  /^# Output to file$/ {if(copy) exit}
  copy
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/windows-function.sh"

python3 - "$WORK_DIR/history.b64" <<'PY'
import base64
import json
import sys

payload = {
    "source": "Windows Update Agent",
    "queried_at": "2026-10-11T12:00:00Z",
    "entries": [{
        "date": "2026-10-11T11:00:00Z",
        "title": "Security <update> & \u2713",
        "kb": ["KB1234567", "KB7654321"],
        "operation": "Installation",
        "result_code": 2,
        "hresult": -2145124329,
        "source": "Windows Update Agent",
    }],
}
with open(sys.argv[1], "wb") as output:
    output.write(base64.b64encode(json.dumps(payload, ensure_ascii=False).encode()))
PY

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
VM=155
NAME=win-history-fixture
OS='"pretty-name" : "Windows Server 2025 Standard"'
GN='' BL='' CL='' OR=''
LOG="$PWD/record"
HISTORY=$(cat "$PWD/history.b64")

WINDOWS_POWERSHELL_ENCODE() { printf encoded; }
PRINT_UPDATE_SPLIT() { :; }
STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$LOG"; }
QEMU_GUEST_EXEC_READONLY() {
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_STDOUT=$(printf 'UU_WINDOWS|history|%s\nUU_WINDOWS|ok|0|false\n' "$HISTORY")
  QEMU_EXEC_OUTPUT="$QEMU_EXEC_STDOUT"
}
source "$PWD/windows-function.sh"
CHECK_VM_QEMU_WINDOWS
grep -Fq 'Windows Update Agent' "$LOG"
grep -Fq 'KB1234567' "$LOG"
grep -Fq 'Security <update>' "$LOG"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"
(cd "$WORK_DIR" && bash harness.sh)

cat > "$WORK_DIR/history-only-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
VM=155
NAME=win-history-fixture
OS='"pretty-name" : "Windows Server 2025 Standard"'
GN='' BL='' CL='' OR=''
LOG="$PWD/history-only-record"
HISTORY=$(cat "$PWD/history.b64")
WINDOWS_POWERSHELL_ENCODE() { [[ "$1" == history && "$2" == 20 ]]; }
STATUS_MODEL_RECORD() { printf '%s\n' "$*" >> "$LOG"; }
QEMU_GUEST_EXEC_READONLY() {
  QEMU_EXEC_TRANSPORT_RC=0
  QEMU_EXEC_EXITCODE=0
  QEMU_EXEC_STDOUT=$(printf 'UU_WINDOWS|history|%s\n' "$HISTORY")
  QEMU_EXEC_OUTPUT="$QEMU_EXEC_STDOUT"
}
source "$PWD/windows-function.sh"
UU_WINDOWS_HISTORY_ONLY=true CHECK_VM_QEMU_WINDOWS
grep -Fq 'history_only' "$LOG"
! grep -Fq 'UU_WINDOWS|ok' "$LOG"
HARNESS
chmod 750 "$WORK_DIR/history-only-harness.sh"
(cd "$WORK_DIR" && bash history-only-harness.sh)

# Optional history metadata is persisted without changing legacy fields.
STATUS_MODEL_FILE="$WORK_DIR/status.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" \
  bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 155 vm qga true "Windows Server 2025" windows-update 0 false ok "" "" node1 win 0 0 \
      '"'"'{"source":"Windows Update Agent","queried_at":"2026-10-11T12:00:00Z","history":[{"title":"Security <update>","result_code":2,"hresult":-2145124329}]}'"'"'
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR/status-model.sh"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
history = target["windows_update"]
assert history["source"] == "Windows Update Agent"
assert history["history"][0]["result_code"] == 2
assert history["history"][0]["hresult"] == -2145124329
PY

STATUS_MODEL_FILE="$WORK_DIR/status.json" bash -c \
  'source "$1"; STATUS_MODEL_UPDATE_RESULT 155 success 0 2 true 5 5' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["last_update"]["result_code"] == 2
assert target["last_update"]["reboot_required"] is True
assert target["last_update"]["processed"] == 5
PY

# Remote/imported records containing both optional JSON objects retain both
# objects, while a legacy name,last_update record remains readable.
python3 - "$WORK_DIR/remote-status.json" <<'PY'
import json
import sys

history = {"source": "Windows Update Agent", "queried_at": "2026-10-11T12:00:00Z", "history": []}
json.dump({"generated_at": "2026-10-11T12:00:00Z", "targets": [
    {"id": "155", "type": "vm", "transport": "qga", "reachable": True,
     "os": "Windows Server 2025", "updater": "windows-update", "updates": {"available": 0},
     "reboot_required": False, "check_status": "ok", "node": "node1", "name": "win",
     "last_update": {"status": "success", "timestamp": "2026-10-11T11:00:00Z", "processed": 5},
     "windows_update": history}
]}, open(sys.argv[1], "w", encoding="utf-8"), separators=(",", ":"))
PY
STATUS_MODEL_FILE="$WORK_DIR/imported.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/import.records" \
  bash -c 'source "$1"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/remote-status.json"
python3 - "$WORK_DIR/imported.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["last_update"]["processed"] == 5
assert target["windows_update"]["source"] == "Windows Update Agent"
PY

python3 - "$WORK_DIR/legacy.records" <<'PY'
import base64
import json
import sys

values = ["155", "vm", "qga", "true", "Windows Server 2025", "windows-update", "0", "false", "ok", "", "", "node1", "win",
          json.dumps({"status": "success", "timestamp": "2026-10-11T11:00:00Z"})]
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write("\t".join(base64.b64encode(value.encode()).decode() for value in values) + "\n")
PY
STATUS_MODEL_FILE="$WORK_DIR/legacy.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/legacy.records" \
  bash -c 'source "$1"; STATUS_MODEL_FINISH' _ "$ROOT_DIR/status-model.sh"
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["last_update"]["status"] == "success"
PY

echo 'Windows Update Agent history regression tests: PASS'
