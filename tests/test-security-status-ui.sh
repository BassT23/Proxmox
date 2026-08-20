#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" bash -c '
  . "$1/status-model.sh"
  STATUS_MODEL_INIT
  STATUS_MODEL_RECORD 191 lxc pct true ubuntu apt 18 false updates_available "" "" node3 Testing-2 14 4
  STATUS_MODEL_FINISH
' _ "$ROOT_DIR"

python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    target = json.load(source)["targets"][0]
assert target["updates"]["available"] == 18
assert target["normal_updates"] == 14
assert target["security_updates"] == 4
assert target["normal_updates"] + target["security_updates"] == target["updates"]["available"]
PY

cat > "$WORK_DIR/import.json" <<'EOF'
{"schema_version":1,"targets":[{"id":"230","type":"lxc","transport":"pct","reachable":true,"os":"ubuntu","updater":"apt","updates":{"available":5},"normal_updates":3,"security_updates":2,"reboot_required":false,"check_status":"updates_available","error":null,"node":"node2","name":"tasmota"}]}
EOF
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/imported.json" \
STATUS_MODEL_RECORD_FILE="$WORK_DIR/import.records" bash -c '
  . "$1/status-model.sh"
  STATUS_MODEL_INIT
  STATUS_MODEL_IMPORT_FILE "$2"
  STATUS_MODEL_FINISH
' _ "$ROOT_DIR" "$WORK_DIR/import.json"
python3 - "$WORK_DIR/imported.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert (target["normal_updates"], target["security_updates"]) == (3, 2)
PY

grep -Fq 'CONTAINER_NORMAL_UPDATES=$NORMAL_APT_UPDATES' "$ROOT_DIR/check-updates.sh"
grep -Fq 'CONTAINER_SECURITY_UPDATES=$SECURITY_APT_UPDATES' "$ROOT_DIR/check-updates.sh"
grep -Fq 'Normal updates: $NORMAL_APT_UPDATES' "$ROOT_DIR/check-updates.sh"
grep -Fq 'Security updates: $SECURITY_APT_UPDATES' "$ROOT_DIR/check-updates.sh"

cat > "$WORK_DIR/apt-output" <<'EOF'
Inst security-one (1.0 Ubuntu-Security)
Inst security-two (2.0 Ubuntu-Security)
Inst ordinary (3.0 Ubuntu)
EOF

source "$ROOT_DIR/target-runtime.sh"
READ_APT_UPDATE_COUNTS "$(cat "$WORK_DIR/apt-output")"
[[ "$NORMAL_APT_UPDATES" == 1 ]]
[[ "$SECURITY_APT_UPDATES" == 2 ]]

python3 - "$ROOT_DIR/web-ui/server.py" <<'PY'
import sys

source = open(sys.argv[1], encoding="utf-8").read()
assert '"DEBUG"' in source
assert "DEBUG:'Debug logging'" in source
assert "Debug logging shows additional technical output" in source
assert "normal_updates" in source and "security_updates" in source
assert "Normal updates" in source and "Security updates" in source
assert "security-warn" in source
assert "Security updates available" in source
PY

echo "security status and UI regression tests: PASS"
