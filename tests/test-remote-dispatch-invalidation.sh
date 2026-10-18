#!/usr/bin/env bash
# shellcheck disable=SC2016 # Static assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"200","type":"vm","node":"node2","check_status":"ok","reachable":true,
   "updates":{"available":3},"package_checked_at":"2026-10-17T10:00:00Z",
   "package_data_invalidated":false,"package_mutation_generation":0,
   "package_mutation_in_progress":false},
  {"id":"201","type":"lxc","node":"node2","check_status":"ok","reachable":true,
   "updates":{"available":1},"package_checked_at":"2026-10-17T10:00:00Z",
   "package_data_invalidated":false,"package_mutation_generation":0,
   "package_mutation_in_progress":false},
  {"id":"host:node2","type":"host","node":"node2","check_status":"ok","reachable":true,
   "updates":{"available":0},"package_checked_at":"2026-10-17T10:00:00Z",
   "package_data_invalidated":false,"package_mutation_generation":0,
   "package_mutation_in_progress":false}
]}
JSON

STATUS_MODEL_FILE="$WORK_DIR/status.json"
LOCAL_FILES="$WORK_DIR"
export STATUS_MODEL_FILE LOCAL_FILES
source "$ROOT_DIR/status-model.sh"

assert_reserved_before_dispatch() {
  local target_id="$1" target_type="$2" target_node="$3" operation_id="$4"
  local dispatched=false
  REMOTE_UPDATE_CONTROLLER_INVALIDATE "$target_id" "$target_type" "$target_node" "$operation_id"
  python3 - "$STATUS_MODEL_FILE" "$target_id" "$target_type" "$target_node" <<'PY'
import json
import sys
path, target_id, target_type, target_node = sys.argv[1:]
payload = json.load(open(path, encoding="utf-8"))
matches = [item for item in payload["targets"]
           if item.get("id") == target_id and item.get("type") == target_type
           and item.get("node") == target_node]
assert len(matches) == 1
assert matches[0]["package_data_invalidated"] is True
assert matches[0]["package_mutation_in_progress"] is True
assert matches[0]["package_mutation_operation_id"]
PY
  dispatched=true
  [[ "$dispatched" == true ]]
}

REMOTE_UPDATE_CONTROLLER_INVALIDATE() {
  local target_id="$1" target_type="$2" target_node="$3" operation_id="$4"
  STATUS_MODEL_FILE="$STATUS_MODEL_FILE" STATUS_MODEL_INVALIDATE_PACKAGE_DATA \
    "$target_id" "$target_type" "$target_node" "$operation_id"
}

assert_reserved_before_dispatch 200 vm node2 uu-op-fixture-vm-20261017T120000
assert_reserved_before_dispatch 201 lxc node2 uu-op-fixture-lxc-20261017T120000
assert_reserved_before_dispatch host:node2 host node2 uu-op-fixture-host-20261017T120000

# An identity mismatch fails before the mocked dispatch point and cannot
# invalidate the external record as a Proxmox LXC.
if REMOTE_UPDATE_CONTROLLER_INVALIDATE 200 external node2 uu-op-fixture-wrong-20261017T120000; then
  echo 'identity mismatch unexpectedly reserved a remote update' >&2
  exit 1
fi

# A stale result from another operation cannot clear the controller epoch.
python3 - "$WORK_DIR/old-remote.json" <<'PY'
import json
import sys
json.dump({"targets": [{
    "id": "200", "type": "vm", "node": "node2", "reachable": True,
    "updater": "apt", "updates": {"available": 0}, "check_status": "ok",
    "package_checked_at": "2026-10-17T11:00:00Z",
    "package_data_invalidated": False, "package_mutation_generation": 1,
    "package_mutation_in_progress": False,
    "package_mutation_operation_id": "uu-op-old-20261017T110000"
}]}, open(sys.argv[1], "w", encoding="utf-8"))
PY
STATUS_MODEL_RECORD_FILE="$WORK_DIR/old.records" STATUS_MODEL_PARTIAL=true \
  STATUS_MODEL_IMPORT_FILE "$WORK_DIR/old-remote.json" 2>/dev/null || true

# Rebuild a clean controller reservation for the operation-order assertions.
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys
path = sys.argv[1]
payload = json.load(open(path, encoding="utf-8"))
for item in payload["targets"]:
    if item["id"] == "200":
        item.update({"package_data_invalidated": False, "package_mutation_in_progress": False,
                     "package_mutation_generation": 0})
json.dump(payload, open(path, "w", encoding="utf-8"))
PY
op=uu-op-fixture-remote-20261017T120000
STATUS_MODEL_INVALIDATE_PACKAGE_DATA 200 vm node2 "$op"

cat > "$WORK_DIR/remote-error.json" <<JSON
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updates":{"available":null},"check_status":"error","error":{"code":"CHECK_COMMAND_FAILED"},
"package_mutation_generation":4,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"$op"}]}
JSON
STATUS_MODEL_RECORD_FILE="$WORK_DIR/error.records" STATUS_MODEL_PARTIAL=true \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' \
  _ "$ROOT_DIR" "$WORK_DIR/remote-error.json"
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys
item = next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is True
assert item["package_mutation_in_progress"] is True
PY

cat > "$WORK_DIR/remote-success.json" <<JSON
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:01:00Z","error":null,
"package_mutation_generation":7,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"$op"}]}
JSON
STATUS_MODEL_RECORD_FILE="$WORK_DIR/success.records" STATUS_MODEL_PARTIAL=true \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' \
  _ "$ROOT_DIR" "$WORK_DIR/remote-success.json"
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys
item = next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is False
assert item["package_mutation_in_progress"] is False
assert item["package_mutation_operation_id"] == "uu-op-fixture-remote-20261017T120000"
assert item["package_mutation_generation"] == 1
assert item["updates"] == {"available": 0}
PY

# A remote worker's generation is local to that worker. It must not clear a
# controller reservation when the completion operation is absent or wrong,
# even if both generations happen to be the same.
reset_controller_reservation() {
  local operation_id="$1" generation="$2"
  python3 - "$STATUS_MODEL_FILE" "$operation_id" "$generation" <<'PY'
import json
import sys
path, operation_id, generation = sys.argv[1:]
payload = json.load(open(path, encoding="utf-8"))
item = next(x for x in payload["targets"] if x["id"] == "200")
item.update({
    "package_checked_at": "2026-10-17T12:00:00Z",
    "updates": {"available": 3},
    "check_status": "ok",
    "reachable": True,
    "package_data_invalidated": True,
    "package_mutation_generation": int(generation),
    "package_mutation_in_progress": False,
    "package_mutation_operation_id": operation_id,
})
json.dump(payload, open(path, "w", encoding="utf-8"))
PY
}

import_remote_fixture() {
  local fixture="$1" records="$2"
  STATUS_MODEL_RECORD_FILE="$records" STATUS_MODEL_PARTIAL=true \
    bash -c 'source "$1/status-model.sh"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' \
    _ "$ROOT_DIR" "$fixture"
}

# Exercise the real successful-check record boundary used by a remote
# post-update capture.  The worker already has the operation reservation, but
# the check caller leaves the positional invalidation field empty.  The
# common record helper must make the successful false provenance explicit so
# the controller can safely complete its matching reservation.
emit_remote_successful_check_record() {
  local operation_id="$1" worker_status="$WORK_DIR/remote-worker-status.json"
  python3 - "$worker_status" "$operation_id" <<'PY'
import json
import sys

path, operation_id = sys.argv[1:]
json.dump({"schema_version": 1, "targets": [{
    "id": "200", "type": "vm", "node": "node2", "reachable": True,
    "os": "Debian", "updater": "apt", "updates": {"available": 0},
    "check_status": "ok", "package_mutation_generation": 1,
    "package_mutation_in_progress": False,
    "package_mutation_operation_id": operation_id,
}]}, open(path, "w", encoding="utf-8"))
PY
  STATUS_MODEL_FILE="$worker_status" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/remote-worker.records" \
  STATUS_MODEL_GENERATION_FILE="$WORK_DIR/remote-worker.generations" \
  STATUS_MODEL_NODE=node2 LOCAL_FILES="$WORK_DIR" \
  UU_PACKAGE_MUTATION_OPERATION_ID="$operation_id" \
    bash -c '
      set -e
      source "$1/status-model.sh"
      STATUS_MODEL_INIT
      STATUS_MODEL_CAPTURE_TARGET_GENERATION 200
      STATUS_MODEL_RECORD 200 vm ssh true Debian apt 0 false ok "" "" node2 vm-200 null null "" now "" "" "" ""
      STATUS_MODEL_FINISH
    ' _ "$ROOT_DIR"
  python3 - "$worker_status" <<'PY'
import json
import sys

item = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert item["package_data_invalidated"] is False
assert item["package_mutation_operation_id"]
PY
  printf '%s\n' "$worker_status"
}

assert_controller_still_invalidated() {
  python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys
item = next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is True
assert item["package_checked_at"] == "2026-10-17T12:00:00Z"
PY
}

reset_controller_reservation uu-op-controller-20261017T123000 1
cat > "$WORK_DIR/remote-missing-operation.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:01:00Z","error":null,
"package_mutation_generation":1,"package_mutation_in_progress":false,
"package_data_invalidated":false}]}
JSON
import_remote_fixture "$WORK_DIR/remote-missing-operation.json" "$WORK_DIR/remote-missing-operation.records"
assert_controller_still_invalidated

# The successful check path must emit explicit false provenance.  Without the
# fix this worker artifact has no package_data_invalidated field and the
# controller remains conservatively invalidated.
reset_controller_reservation uu-op-controller-20261017T123000 1
worker_status=$(emit_remote_successful_check_record uu-op-controller-20261017T123000)
import_remote_fixture "$worker_status" "$WORK_DIR/remote-worker.records.import"
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys

item = next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is False
assert item["package_mutation_in_progress"] is False
assert item["package_mutation_operation_id"] == "uu-op-controller-20261017T123000"
PY

reset_controller_reservation uu-op-controller-20261017T123000 1
cat > "$WORK_DIR/remote-wrong-operation.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:01:00Z","error":null,
"package_mutation_generation":1,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"uu-op-wrong"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-wrong-operation.json" "$WORK_DIR/remote-wrong-operation.records"
assert_controller_still_invalidated

reset_controller_reservation uu-op-controller-20261017T123000 1
cat > "$WORK_DIR/remote-invalid-result.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":null},"check_status":"error",
"error":{"code":"CHECK_COMMAND_FAILED"},
"package_mutation_generation":1,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"uu-op-controller-20261017T123000"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-invalid-result.json" "$WORK_DIR/remote-invalid-result.records"
assert_controller_still_invalidated

# A valid remote post-check may clear the reservation only with the exact
# operation ID and an independent remote generation. The controller keeps
# its own generation; the two counters are never compared as an identity.
reset_controller_reservation uu-op-controller-20261017T123000 1
cat > "$WORK_DIR/remote-valid-completion.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:02:00Z","error":null,
"package_mutation_generation":99,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"uu-op-controller-20261017T123000"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-valid-completion.json" "$WORK_DIR/remote-valid-completion.records"
python3 - "$STATUS_MODEL_FILE" <<'PY'
import json
import sys
item = next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is False
assert item["package_mutation_generation"] == 1
assert item["package_mutation_operation_id"] == "uu-op-controller-20261017T123000"
assert item["package_checked_at"] == "2026-10-17T12:02:00Z"
PY

# A newer controller operation rejects a valid result from the old operation,
# regardless of the imported timestamp or generation.
reset_controller_reservation uu-op-controller-new 2
cat > "$WORK_DIR/remote-old-operation.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:03:00Z","error":null,
"package_mutation_generation":1,"package_mutation_in_progress":false,
"package_data_invalidated":false,"package_mutation_operation_id":"uu-op-controller-old"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-old-operation.json" "$WORK_DIR/remote-old-operation.records"
assert_controller_still_invalidated

# A source result captured while the remote mutation was active is not a
# completion, even when it carries the right operation ID.
reset_controller_reservation uu-op-controller-active 3
cat > "$WORK_DIR/remote-during-mutation.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updater":"apt","updates":{"available":0},"check_status":"ok",
"package_checked_at":"2026-10-17T12:04:00Z","error":null,
"package_mutation_generation":7,"package_mutation_in_progress":true,
"package_data_invalidated":false,"package_mutation_operation_id":"uu-op-controller-active"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-during-mutation.json" "$WORK_DIR/remote-during-mutation.records"
assert_controller_still_invalidated

# History-only imports never complete a mutation operation.
reset_controller_reservation uu-op-controller-history 4
cat > "$WORK_DIR/remote-history.json" <<'JSON'
{"targets":[{"id":"200","type":"vm","node":"node2","reachable":true,
"updates":{"available":0},"check_status":"history_only",
"last_check":"2026-10-17T12:05:00Z","package_mutation_generation":4,
"package_mutation_in_progress":false,"package_data_invalidated":false,
"package_mutation_operation_id":"uu-op-controller-history"}]}
JSON
import_remote_fixture "$WORK_DIR/remote-history.json" "$WORK_DIR/remote-history.records"
assert_controller_still_invalidated

# Static assertions ensure every supported remote update entry point reserves
# the controller epoch after transport/identity checks and before dispatch.
grep -Fq 'REMOTE_UPDATE_CONTROLLER_INVALIDATE "host:$RESOLVED_NODE" host "$RESOLVED_NODE"' "$ROOT_DIR/ultimate-updater"
grep -Fq 'REMOTE_UPDATE_CONTROLLER_INVALIDATE "$target" "$status_target_type" "$RESOLVED_TARGET_NODE"' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_PACKAGE_MUTATION_OPERATION_ID=%q' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_PACKAGE_MUTATION_OPERATION_ID=%q' "$ROOT_DIR/update.sh"
grep -Fq 'UU_PACKAGE_MUTATION_OPERATION_ID=$UU_PACKAGE_MUTATION_OPERATION_ID' "$ROOT_DIR/job-runner.sh"

# Exercise the real run_update dispatch boundary: the mocked remote dispatch
# may proceed only after the production controller reservation is visible.
cat > "$WORK_DIR/dispatch-status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"200","type":"vm","node":"node2",
"check_status":"ok","reachable":true,"updates":{"available":2},
"package_checked_at":"2026-10-17T10:00:00Z","package_data_invalidated":false,
"package_mutation_generation":0,"package_mutation_in_progress":false}]}
JSON
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/job-runner"
chmod 755 "$WORK_DIR/job-runner"
awk '/^run_update\(\) \{/{capture=1} capture{if ($0 ~ /update jobs require root/) print "  :"; else print} capture && /^}/ {exit}' \
  "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/run-update-function.sh"
UU_LOCAL_FILES="$ROOT_DIR" bash -c '
  set -euo pipefail
  source "$1/ultimate-updater" help >/dev/null 2>&1
  source "$2/run-update-function.sh"
  STATUS_FILE="$2/dispatch-status.json"
  STATUS_MODEL_FILE="$STATUS_FILE"
  JOB_RUNNER="$2/job-runner"
  resolve_target_kind() {
    RESOLVED_TARGET_KIND=vm
    RESOLVED_TARGET_NODE=node2
    RESOLVED_TARGET_HOST=192.0.2.20
    RESOLVED_TARGET_LOCAL=false
    return 0
  }
  api_verify_resolved_identity() { return 0; }
  resolve_remote_node_transport() { REMOTE_NODE_HOST=192.0.2.20; return 0; }
  remote_target_update() {
    python3 - "$STATUS_FILE" <<"PY"
import json,sys
item=next(x for x in json.load(open(sys.argv[1], encoding="utf-8"))["targets"] if x["id"] == "200")
assert item["package_data_invalidated"] is True
assert item["package_mutation_in_progress"] is True
assert item["package_mutation_operation_id"].startswith("uu-op-")
PY
  }
  run_update 200
' _ "$ROOT_DIR" "$WORK_DIR"

printf '%s\n' 'remote dispatch invalidation tests: PASS'
