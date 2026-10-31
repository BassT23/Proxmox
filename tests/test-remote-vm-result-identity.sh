#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

write_empty_status() {
  printf '%s\n' '{"schema_version":1,"targets":[]}' > "$WORK_DIR/status.json"
}

write_empty_status

# A remote worker starts with no controller status file.  The authoritative
# identity supplied by the controller must make the first result record a VM,
# not silently manufacture an External target.
STATUS_MODEL_FILE="$WORK_DIR/status.json" LOCAL_FILES="$WORK_DIR" \
UU_API_EXPECTED_TARGET_ID=922 UU_API_EXPECTED_TARGET_KIND=vm \
UU_API_EXPECTED_TARGET_NODE=node2 UU_API_EXPECTED_TARGET_LOCAL=remote \
UU_PACKAGE_MUTATION_OPERATION_ID=uu-op-vm-20261031T120000 \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_UPDATE_RESULT 922 completed 0 "" "" 6 6' \
  _ "$ROOT_DIR"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert (item["id"], item["type"], item["node"]) == ("922", "vm", "node2")
assert item["last_update"]["pending_before"] == 6
assert item["last_update"]["status"] == "completed"
PY

# The normal post-update VM capture must merge into the same identity without
# triggering the existing fail-closed type gate.
STATUS_MODEL_FILE="$WORK_DIR/status.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/records" \
STATUS_MODEL_GENERATION_FILE="$WORK_DIR/generations" STATUS_MODEL_PARTIAL=true \
STATUS_MODEL_NODE=node2 LOCAL_FILES="$WORK_DIR" \
UU_PACKAGE_MUTATION_OPERATION_ID=uu-op-vm-20261031T120000 \
  bash -c '
    source "$1/status-model.sh"
    STATUS_MODEL_INIT
    STATUS_MODEL_CAPTURE_TARGET_GENERATION 922
    STATUS_MODEL_RECORD 922 vm ssh true Debian apt 0 false ok "" "" node2 vm-922 0 0 "" now false
    STATUS_MODEL_FINISH
  ' _ "$ROOT_DIR"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert item["type"] == "vm"
assert item["node"] == "node2"
assert item["package_data_invalidated"] is False
assert item["package_mutation_in_progress"] is False
assert item["last_update"]["status"] == "completed"
PY

# An incompatible existing record is still rejected; the identity fix must not
# weaken the status model's fail-closed gate.
printf '%s\n' '{"schema_version":1,"targets":[{"id":"922","type":"external","node":null,"updates":{"available":6}}]}' > "$WORK_DIR/mismatch.json"
cp -- "$WORK_DIR/mismatch.json" "$WORK_DIR/mismatch.before"
if STATUS_MODEL_FILE="$WORK_DIR/mismatch.json" LOCAL_FILES="$WORK_DIR" \
  UU_API_EXPECTED_TARGET_ID=922 UU_API_EXPECTED_TARGET_KIND=vm UU_API_EXPECTED_TARGET_NODE=node2 \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_UPDATE_RESULT 922 success 0 "" "" "" 6' \
  _ "$ROOT_DIR" 2>"$WORK_DIR/mismatch.err"; then
  echo 'contaminated VM result unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'STATUS_MODEL_UPDATE_REJECTED_TARGET_IDENTITY' "$WORK_DIR/mismatch.err"
cmp -s "$WORK_DIR/mismatch.json" "$WORK_DIR/mismatch.before"

# A numeric result without authoritative type context must fail closed rather
# than falling back to type=external.  Explicit external context remains valid.
write_empty_status
cp -- "$WORK_DIR/status.json" "$WORK_DIR/missing-type.before"
if STATUS_MODEL_FILE="$WORK_DIR/status.json" LOCAL_FILES="$WORK_DIR" \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_UPDATE_RESULT 922 failed 1' \
  _ "$ROOT_DIR" 2>"$WORK_DIR/missing-type.err"; then
  echo 'numeric result without type unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'numeric target type is missing' "$WORK_DIR/missing-type.err"
cmp -s "$WORK_DIR/status.json" "$WORK_DIR/missing-type.before"

# Unknown guest results remain visible in the existing summary bucket; the
# identity fix must not create a path that silently drops them.
printf '%s\n' '{"targets":[{"id":"922","type":"vm","node":"node2","name":"VM 922","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"unknown"}}]}' > "$WORK_DIR/summary.json"
LOCAL_FILES="$WORK_DIR" bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' \
  _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/summary.json" > "$WORK_DIR/summary.txt"
grep -Fq 'Results unavailable:' "$WORK_DIR/summary.txt"
grep -Fq 'VM 922' "$WORK_DIR/summary.txt"

write_empty_status
STATUS_MODEL_FILE="$WORK_DIR/status.json" LOCAL_FILES="$WORK_DIR" \
UU_API_EXPECTED_TARGET_ID=external-test UU_API_EXPECTED_TARGET_KIND=external \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_UPDATE_RESULT external-test failed 1' \
  _ "$ROOT_DIR"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert item["type"] == "external"
assert item.get("node") in (None, "")
PY

# Exercise the real direct numeric remote-dispatch command construction with
# local mocks only.  The worker must receive the controller's VM identity.
awk '/^ARGUMENTS \(\)/ { capture=1 } capture { print } /^# Check Updates for Welcome-Screen/ { exit }' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/arguments.sh"
cat > "$WORK_DIR/job-runner.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REMOTE_JOB_LOG"
EOF
chmod 750 "$WORK_DIR/job-runner.sh"

REMOTE_COMMAND_LOG="$WORK_DIR/remote-command.log"
REMOTE_JOB_LOG="$WORK_DIR/remote-job.log"
export REMOTE_COMMAND_LOG REMOTE_JOB_LOG
bash -c '
    set -euo pipefail
    declare -A UPDATE_PENDING_BEFORE=()
    LOCAL_FILES="$1"
    SSH_PORT=22
    UU_CLUSTER_RESOURCES_JSON=fixture
    COMMAND=false
    SINGLE_UPDATE=false
    MODE=""
    ONLY=""
    UPDATE_PENDING_BEFORE[922]=6
    STATUS_MODEL_NEW_OPERATION_ID() { printf "%s\n" uu-op-vm-20261031T120000; }
    cluster_target_resolve() {
      CLUSTER_TARGET_KIND=vm
      CLUSTER_TARGET_NODE=node2
      CLUSTER_TARGET_HOST=192.0.2.22
      CLUSTER_TARGET_LOCAL=false
      return 0
    }
    API_UPDATE_TARGET_IDENTITY_GUARD() { return 0; }
    MARK_PACKAGE_DATA_INVALIDATED() { return 0; }
    CAPTURE_UPDATE_PENDING_BEFORE() { UPDATE_PENDING_BEFORE[922]=6; }
    ssh() {
      local command="${!#}"
      printf "%s\n" "$command" >> "$REMOTE_COMMAND_LOG"
      printf "Update job started\nTarget: 922\nJob: ultimate-updater-update-922-fixture\n"
    }
    source "$1/arguments.sh"
    ARGUMENTS 922
' _ "$WORK_DIR"

grep -Fq 'UU_API_ACTION=update' "$REMOTE_COMMAND_LOG"
grep -Fq 'UU_API_EXPECTED_TARGET_ID=922' "$REMOTE_COMMAND_LOG"
grep -Fq 'UU_API_EXPECTED_TARGET_KIND=vm' "$REMOTE_COMMAND_LOG"
grep -Fq 'UU_API_EXPECTED_TARGET_NODE=node2' "$REMOTE_COMMAND_LOG"
grep -Fq 'UU_API_EXPECTED_TARGET_LOCAL=remote' "$REMOTE_COMMAND_LOG"

echo 'remote VM result identity regression: PASS'
