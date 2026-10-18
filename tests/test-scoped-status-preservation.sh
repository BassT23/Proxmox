#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Exercise the actual direct check dispatcher, without sourcing the rest of
# check-updates.sh or invoking qm/pct/SSH/QGA.
awk '/^ARGUMENTS \(\) \{/{copy=1} /^# Usage$/{if(copy) exit} copy' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/arguments.sh"
cat > "$WORK_DIR/dispatcher-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
CHECK_FAILURE=0 COMMAND=false RICM=false RDU=false
WITH_HOST=true WITH_LXC=true WITH_VM=true USE_INTERNAL_TARGET_SELECTION=false
OUTPUT_TO_FILE() { :; }
CHECK_HOST_ITSELF() { :; }
CHECK_SINGLE_CONTAINER() { :; }
CHECK_VM_LIFECYCLE() { :; }
CONTAINER_CHECK_START() { :; }
VM_CHECK_START() { :; }
HOST_CHECK_START() { :; }
source "$PWD/arguments.sh"
for mode in chost node-host ccontainer cvm; do
  STATUS_MODEL_PARTIAL=false
  case "$mode" in
    ccontainer|cvm) ARGUMENTS "$mode" 155 ;;
    *) ARGUMENTS "$mode" ;;
  esac
  [[ "$STATUS_MODEL_PARTIAL" == true ]]
done
HARNESS
chmod 750 "$WORK_DIR/dispatcher-harness.sh"
(cd "$WORK_DIR" && bash dispatcher-harness.sh)

cat > "$WORK_DIR/status.json" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-10-11T11:00:00Z",
  "targets": [
    {"id":"node1","type":"host","check_status":"success"},
    {"id":"node2","type":"host","check_status":"success"},
    {"id":"100","type":"vm","check_status":"success","updates":2},
    {"id":"155","type":"vm","check_status":"ok","updates":4,
     "last_update":{"status":"success","timestamp":"2026-10-10T10:00:00Z","exit_code":0}}
  ]
}
JSON

cat > "$WORK_DIR/status-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$PWD"
STATUS_MODEL_FILE="$PWD/status.json"
STATUS_MODEL_RECORD_FILE="$PWD/status.records"
STATUS_MODEL_SCRIPT="$PWD/status-model.sh"
source "$STATUS_MODEL_SCRIPT"
STATUS_MODEL_INIT
STATUS_MODEL_CAPTURE_TARGET_GENERATION 155
STATUS_MODEL_RECORD 155 vm qga true 'Windows Server 2025' windows-update 0 false ok '' '' node1 '' null null "" now
STATUS_MODEL_PARTIAL=true STATUS_MODEL_FINISH
HARNESS
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/status-model.sh"
chmod 750 "$WORK_DIR/status-harness.sh"
(cd "$WORK_DIR" && bash status-harness.sh)

python3 - "$WORK_DIR/status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
targets = {str(item["id"]): item for item in payload["targets"]}
assert set(targets) == {"node1", "node2", "100", "155"}
assert targets["node1"]["check_status"] == "success"
assert targets["node2"]["check_status"] == "success"
assert targets["100"]["updates"] == 2
assert targets["155"]["check_status"] == "ok"
assert targets["155"]["updates"]["available"] == 0
assert targets["155"]["last_update"]["exit_code"] == 0
PY

# A failed scoped check preserves the same unrelated targets and remains an
# actual failure rather than being converted into success.
sed 's/STATUS_MODEL_RECORD 155.*/STATUS_MODEL_RECORD 155 vm ssh false "" "" null null error SSH_TRANSPORT "connection timed out" node1 "" null null/' \
  "$WORK_DIR/status-harness.sh" | sed 's#status.json#failed-status.json#g; s#status.records#failed-status.records#g' > "$WORK_DIR/failed-harness.sh"
cp "$WORK_DIR/status.json" "$WORK_DIR/failed-status.json"
(cd "$WORK_DIR" && bash failed-harness.sh)
python3 - "$WORK_DIR/failed-status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
targets = {str(item["id"]): item for item in payload["targets"]}
assert set(targets) == {"node1", "node2", "100", "155"}
assert targets["155"]["check_status"] == "error"
assert targets["155"]["error"]["code"] == "SSH_TRANSPORT"
assert targets["100"]["updates"] == 2
PY

# An invalid existing global file must remain untouched during a scoped write.
printf '{invalid\n' > "$WORK_DIR/invalid.json"
sed 's#status.json#invalid.json#g; s#status.records#invalid.records#g' \
  "$WORK_DIR/status-harness.sh" > "$WORK_DIR/invalid-harness.sh"
if (cd "$WORK_DIR" && bash invalid-harness.sh) 2>"$WORK_DIR/invalid.err"; then
  echo 'invalid existing status unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'STATUS_MODEL_PARTIAL_REJECTED_EXISTING_STATE' "$WORK_DIR/invalid.err"
grep -Fq '{invalid' "$WORK_DIR/invalid.json"

# A genuine full capture may replace the target set; this distinguishes it
# from the scoped behavior above.
sed 's#status.json#full-status.json#g; s#status.records#full-status.records#g; s/STATUS_MODEL_PARTIAL=true STATUS_MODEL_FINISH/STATUS_MODEL_PARTIAL=false STATUS_MODEL_FINISH/' \
  "$WORK_DIR/status-harness.sh" > "$WORK_DIR/full-harness.sh"
cp "$WORK_DIR/status.json" "$WORK_DIR/full-status.json"
(cd "$WORK_DIR" && bash full-harness.sh)
python3 - "$WORK_DIR/full-status.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
ids = [str(item["id"]) for item in payload["targets"]]
assert ids == ["155"]
PY

echo 'scoped status preservation regression: PASS'
