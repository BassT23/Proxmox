#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

run_invalidate() {
  local status_file="$1" target_id="$2" target_type="$3" target_node="$4"
  local operation_id="$5"
  LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$status_file" bash -c '
    source "$1/status-model.sh"
    STATUS_MODEL_INVALIDATE_PACKAGE_DATA "$2" "$3" "$4" "$5"
  ' _ "$ROOT_DIR" "$target_id" "$target_type" "$target_node" "$operation_id"
}

# A 5.1 guest record was persisted as an External alias without check_status.
# The current authoritative LXC identity is repaired in place and reserved.
cat > "$WORK_DIR/legacy.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":101,"type":"external","node":null,"reachable":true,
   "updates":{"available":4},"last_update":{"status":"unknown","timestamp":null}},
  {"id":"keep","type":"external","node":null,"check_status":"ok",
   "reachable":true,"updates":{"available":0}}
]}
JSON
run_invalidate "$WORK_DIR/legacy.json" 101 lxc node1 uu-op-legacy-20261116T120000
python3 - "$WORK_DIR/legacy.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if str(item["id"]) == "101")
assert target["id"] == "101"
assert target["type"] == "lxc"
assert target["node"] == "node1"
assert target["package_data_invalidated"] is True
assert target["package_mutation_in_progress"] is True
assert target["package_mutation_operation_id"] == "uu-op-legacy-20261116T120000"
PY

# A current inventory target may be missing from a non-empty old status file.
# Its newly created record is reserved before any package mutation.
cat > "$WORK_DIR/missing.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"keep","type":"lxc","node":"node1","check_status":"ok",
   "reachable":true,"updates":{"available":0}}
]}
JSON
run_invalidate "$WORK_DIR/missing.json" 103 lxc node1 uu-op-missing-20261116T120000
python3 - "$WORK_DIR/missing.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
target = next(item for item in payload["targets"] if str(item["id"]) == "103")
assert target["type"] == "lxc"
assert target["node"] == "node1"
assert target["check_status"] == "not_checked"
assert target["package_data_invalidated"] is True
assert target["package_mutation_in_progress"] is True
PY

# Modern records with an incompatible identity are not migrations.  The
# rejection must leave the status model byte-for-byte unchanged.
cat > "$WORK_DIR/modern-mismatch.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"101","type":"external","node":null,"check_status":"ok",
   "reachable":true,"updates":{"available":4}}
]}
JSON
cp "$WORK_DIR/modern-mismatch.json" "$WORK_DIR/modern-mismatch.before"
if run_invalidate "$WORK_DIR/modern-mismatch.json" 101 lxc node1 uu-op-mismatch-20261116T120000; then
  echo 'modern incompatible identity unexpectedly migrated' >&2
  exit 1
fi
cmp -s "$WORK_DIR/modern-mismatch.json" "$WORK_DIR/modern-mismatch.before"

# Multiple aliases remain ambiguous and cannot be selected by ID alone.
cat > "$WORK_DIR/ambiguous.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"101","type":"external","node":null,"updates":{"available":4}},
  {"id":101,"type":"external","node":null,"updates":{"available":5}}
]}
JSON
cp "$WORK_DIR/ambiguous.json" "$WORK_DIR/ambiguous.before"
if run_invalidate "$WORK_DIR/ambiguous.json" 101 lxc node1 uu-op-ambiguous-20261116T120000; then
  echo 'ambiguous legacy identity unexpectedly migrated' >&2
  exit 1
fi
cmp -s "$WORK_DIR/ambiguous.json" "$WORK_DIR/ambiguous.before"

# Missing External targets remain fail-closed when a status file already has
# content, because no local authoritative identity is available.
if run_invalidate "$WORK_DIR/missing.json" absent external "" uu-op-external-20261116T120000; then
  echo 'missing external identity unexpectedly created' >&2
  exit 1
fi

printf '%s\n' 'legacy status identity invalidation tests: PASS'
