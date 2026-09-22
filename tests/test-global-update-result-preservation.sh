#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/jobs/remote" "$WORK_DIR/remote-work" "$WORK_DIR/bin"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"
cp "$ROOT_DIR/ultimate-updater" "$WORK_DIR/local/ultimate-updater"
chmod 755 "$WORK_DIR/local/ultimate-updater"

cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true,"updates":{"available":1}},
  {"id":"101","type":"vm","node":"node1","name":"vm-101","check_status":"ok","reachable":true,"updates":{"available":2}},
  {"id":"external-linux","type":"external","name":"external-linux","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON
cat > "$WORK_DIR/update-snapshot.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","last_update":{"status":"success","timestamp":"2026-09-22T10:00:01Z","exit_code":0}},
  {"id":"101","last_update":{"status":"success","timestamp":"2026-09-22T10:00:02Z","exit_code":0}},
  {"id":"external-linux","last_update":{"status":"success","timestamp":"2026-09-22T10:00:03Z","exit_code":0}},
  {"id":"stale-target","last_update":{"status":"success","timestamp":"2026-09-22T10:00:04Z","exit_code":0}}
]}
JSON
cat > "$WORK_DIR/remote-work/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node2","type":"host","node":"node2","name":"node2","os":"Proxmox","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"last_update":{"status":"success","timestamp":"2026-09-22T10:00:05Z","exit_code":0}},
  {"id":"200","type":"vm","node":"node2","name":"vm-200","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:06Z","exit_code":0}},
  {"id":"201","type":"lxc","node":"node2","name":"ct-201","check_status":"error","reachable":true,"updates":{"available":null},"last_update":{"status":"failed","timestamp":"2026-09-22T10:00:07Z","exit_code":42}},
  {"id":"999","type":"vm","node":"node3","name":"foreign","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","timestamp":"2026-09-22T10:00:08Z","exit_code":0}}
]}
JSON
printf '0\n' > "$WORK_DIR/remote-work/post-update-status.rc"
cat > "$WORK_DIR/remote-state" <<'STATE'
unit=ultimate-updater-update-node-node2-test
target=node-node2
state=completed
started_at=2026-09-22T10:00:00Z
finished_at=2026-09-22T10:00:09Z
exit_code=0
type=update
source=remote
interactive=false
STATE

cat > "$WORK_DIR/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
command="${@: -1}"
case "$command" in
  *".state"*) cat "$WORK_DIR/remote-state" ;;
  *"$REMOTE_WORKSPACE/status.json"*) cat "$REMOTE_ARTIFACT_DIR/status.json" ;;
  *"$REMOTE_WORKSPACE/post-update-status.rc"*) cat "$REMOTE_ARTIFACT_DIR/post-update-status.rc" ;;
  *"rm -rf"*) : ;;
  *) echo "unexpected fake ssh command: $command" >&2; exit 1 ;;
esac
SSH
chmod 755 "$WORK_DIR/bin/ssh"

export PATH="$WORK_DIR/bin:$PATH" WORK_DIR
export REMOTE_WORKSPACE="/tmp/ultimate-updater-update-node-123-1-1"
export REMOTE_ARTIFACT_DIR="$WORK_DIR/remote-work"
export UU_LOCAL_FILES="$WORK_DIR/local" UU_JOB_STATE_DIR="$WORK_DIR/jobs"
export LOCAL_FILES="$WORK_DIR/local"
export UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote"
export REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote"
export UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json"
export UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh"
export UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater"

"$ROOT_DIR/job-runner.sh" record-remote \
  ultimate-updater-update-node-node2-test node-node2 node2 remote-node 22 "$REMOTE_WORKSPACE"
"$ROOT_DIR/job-runner.sh" list >/dev/null

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"
STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  STATUS_MODEL_PRESERVE_UPDATE_RESULTS "$WORK_DIR/update-snapshot.json" "2026-09-22T10:00:00Z"

python3 - "$WORK_DIR/local/status.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {item["id"]: item for item in payload["targets"]}
assert set(targets) == {"host:node1", "host:node2", "101", "200", "201", "external-linux"}
assert targets["host:node1"]["last_update"]["status"] == "success"
assert targets["101"]["last_update"]["status"] == "success"
assert targets["200"]["last_update"]["status"] == "success"
assert targets["201"]["last_update"]["status"] == "failed"
assert targets["201"]["last_update"]["exit_code"] == 42
assert targets["external-linux"]["last_update"]["status"] == "success"
assert "999" not in targets
assert "stale-target" not in targets
PY

notification=$(STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  bash -c 'source "$1"; STATUS_MODEL_RENDER_NOTIFICATION "$2" update' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status.json")
grep -Fq 'node2' <<< "$notification"
grep -Fq 'vm-200' <<< "$notification"
grep -Fq 'ct-201' <<< "$notification"
grep -Fq 'external-linux' <<< "$notification"
if grep -Fq 'Result unavailable' <<< "$notification"; then
  echo 'remote result rendered as unavailable' >&2
  exit 1
fi

# Remote update workspaces must contain every structured count helper used by
# their post-update checks, including the APT helper reported missing in #350.
grep -Fq "local apt_count_file=\"\$LOCAL_FILES/apt-count.py\"" "$ROOT_DIR/ultimate-updater"
grep -Fq "local rpm_count_file=\"\$LOCAL_FILES/rpm-count.py\"" "$ROOT_DIR/ultimate-updater"
grep -Fq "local package_count_file=\"\$LOCAL_FILES/package-count.sh\"" "$ROOT_DIR/ultimate-updater"
grep -Fq "\"\$LOCAL_FILES/target-runtime.sh\" \"\$apt_count_file\" \"\$rpm_count_file\" \"\$package_count_file\"" "$ROOT_DIR/ultimate-updater"

echo 'global update result preservation regression: PASS'
