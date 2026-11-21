#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
# Cluster controller reservation of node host records.
#
# The controller reserves a REMOTE node's host record (operation ID handed to
# the node's worker) and completes it afterwards.  It must NOT reserve its own
# node: the local child's baseline preflight rejects a host record with an
# active mutation, so a controller-side reservation made every local host
# update fail with PENDING_BEFORE_INVALID.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Real reservation helpers and the real UPDATE_HOST; everything that touches a
# node (ssh, scp, hostname -i) is mocked.
awk '/^MARK_PACKAGE_DATA_INVALIDATED\(\) \{/{copy=1} /^CLEAR_PACKAGE_MUTATION_RESERVATIONS\(\) \{/{if(copy) exit} copy' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/functions.sh"
awk '/^UPDATE_HOST \(\) \{/{copy=1} copy{print} copy && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" >> "$WORK_DIR/functions.sh"

cat > "$WORK_DIR/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$1
WORK_DIR=$2
TARGET=$3          # local | remote
export LOCAL_FILES="$WORK_DIR/local"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
mkdir -p "$LOCAL_FILES/VMs"
: > "$LOCAL_FILES/product-metadata.sh"
SSH_LOG="$WORK_DIR/ssh.log"
: > "$SSH_LOG"

CONTROLLER_IP=10.9.9.1
REMOTE_IP=10.9.9.2
cat > "$STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[
 {"id":"host:ctl","type":"host","node":"ctl","reachable":true,"check_status":"ok","updates":{"available":0},"last_check":"2026-01-01T00:00:00Z","package_checked_at":"2026-01-01T00:00:00Z","package_data_invalidated":false,"package_mutation_in_progress":false},
 {"id":"host:other","type":"host","node":"other","reachable":true,"check_status":"ok","updates":{"available":0},"last_check":"2026-01-01T00:00:00Z","package_checked_at":"2026-01-01T00:00:00Z","package_data_invalidated":false,"package_mutation_in_progress":false}
]}
JSON

declare -A PACKAGE_MUTATION_KEYS=()
declare -A PACKAGE_MUTATION_OPERATIONS=()
declare -a PACKAGE_MUTATION_TARGETS=()
UPDATE_FAILURE=false
SSH_PORT=22
WELCOME_SCREEN=false
UPDATE_WARNING_RC=10
SCRIPT_DIR="$WORK_DIR"
REMOTE_UPDATE_STATUS=""
USE_INTERNAL_TARGET_SELECTION=false

hostname() {
  if [[ "${1:-}" == -i ]]; then printf '%s\n' "$CONTROLLER_IP"; else printf 'ctl\n'; fi
}
# Only the node worker call (bash -s) carries the worker's exit code.
ssh() {
  printf '%s\n' "$*" >> "$SSH_LOG"
  [[ "$*" == *"bash -s"* ]] && return "${MOCK_SSH_RC:-0}"
  return 0
}
scp() { return 0; }
EFFECTIVE_HEADLESS() { return 0; }

source "$ROOT_DIR/status-model.sh"
source "$WORK_DIR/functions.sh"
REQUIRE_PACKAGE_DATA_INVALIDATION() { return 0; }

if [[ "$TARGET" == local ]]; then
  HOST_NODE=ctl
  HOST=$CONTROLLER_IP
else
  HOST_NODE=other
  HOST=$REMOTE_IP
fi
MOCK_SSH_RC=${MOCK_SSH_RC:-0}
if UPDATE_HOST "$HOST"; then rc=0; else rc=$?; fi
printf 'rc=%s failure=%s\n' "$rc" "$UPDATE_FAILURE" > "$WORK_DIR/result"
HARNESS
chmod 750 "$WORK_DIR/harness.sh"

run_case() {
  local name=$1 target=$2 ssh_rc=${3:-0}
  rm -rf -- "$WORK_DIR/case-$name"
  mkdir -p -- "$WORK_DIR/case-$name"
  cp "$WORK_DIR/functions.sh" "$WORK_DIR/harness.sh" "$WORK_DIR/case-$name/"
  MOCK_SSH_RC=$ssh_rc bash "$WORK_DIR/case-$name/harness.sh" "$ROOT_DIR" \
    "$WORK_DIR/case-$name" "$target" > "$WORK_DIR/case-$name/output" 2>&1 || {
      cat "$WORK_DIR/case-$name/output" >&2
      return 1
    }
}

# Local node: no controller-side reservation and no completion, whatever the
# child exit code is.
run_case local local
python3 - "$WORK_DIR/case-local" <<'PY'
import json
import sys

case = sys.argv[1]
payload = json.load(open(f"{case}/status.json", encoding="utf-8"))
record = next(item for item in payload["targets"] if item["id"] == "host:ctl")
assert record["package_mutation_in_progress"] is False, record
assert record["package_data_invalidated"] is False, record
assert "package_mutation_operation_id" not in record, record
result = open(f"{case}/result", encoding="utf-8").read()
assert "rc=0 failure=false" in result, result
ssh_log = open(f"{case}/ssh.log", encoding="utf-8").read()
assert "bash -s" in ssh_log, ssh_log
assert "UU_PACKAGE_MUTATION_OPERATION_ID" not in ssh_log, ssh_log
PY

run_case local-warning local 10
grep -Fq 'rc=10 failure=false' "$WORK_DIR/case-local-warning/result"
python3 - "$WORK_DIR/case-local-warning/status.json" <<'PY'
import json
import sys

record = next(item for item in json.load(open(sys.argv[1], encoding="utf-8"))["targets"]
              if item["id"] == "host:ctl")
assert "package_mutation_operation_id" not in record, record
PY

# Remote node: reserved before the dispatch under the operation handed to the
# worker, completed afterwards (in_progress false) with the same operation.
run_case remote remote
python3 - "$WORK_DIR/case-remote" <<'PY'
import json
import re
import sys

case = sys.argv[1]
payload = json.load(open(f"{case}/status.json", encoding="utf-8"))
record = next(item for item in payload["targets"] if item["id"] == "host:other")
operation = record["package_mutation_operation_id"]
assert operation.startswith("uu-op-"), record
assert record["package_mutation_in_progress"] is False, record
assert record["package_data_invalidated"] is True, record
ssh_log = open(f"{case}/ssh.log", encoding="utf-8").read()
assert re.search(r"UU_PACKAGE_MUTATION_OPERATION_ID=" + re.escape(operation) + r"\b", ssh_log), ssh_log
other = next(item for item in payload["targets"] if item["id"] == "host:ctl")
assert "package_mutation_operation_id" not in other, other
PY

# Worker exit code to job state: 10 (nothing to update) is a warning, not a failure.
run_case remote-noop remote 10
grep -Fq 'rc=10 failure=false' "$WORK_DIR/case-remote-noop/result"
grep -Fq 'state=completed_with_warnings' "$WORK_DIR/case-remote-noop/ssh.log"
run_case remote-ok remote 0
grep -Fq 'state=completed;' "$WORK_DIR/case-remote-ok/ssh.log"
run_case remote-failed remote 1
grep -Fq 'state=failed' "$WORK_DIR/case-remote-failed/ssh.log"

printf '%s\n' 'cluster host reservation regression: PASS'
