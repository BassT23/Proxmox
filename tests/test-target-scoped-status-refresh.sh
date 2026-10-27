#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

SCOPED_DIR="$WORK_DIR/scoped"
REMOTE_DIR="$WORK_DIR/remote"
mkdir -p "$SCOPED_DIR/jobs/remote" "$SCOPED_DIR/bin" "$REMOTE_DIR"
cp -- "$ROOT_DIR/ultimate-updater" "$ROOT_DIR/job-runner.sh" "$SCOPED_DIR/"

cat > "$SCOPED_DIR/status-model.sh" <<'EOF'
#!/usr/bin/env bash
STATUS_MODEL_VALIDATE_TARGET_FILE() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    payload = json.load(source)
targets = payload.get("targets", [])
raise SystemExit(0 if len(targets) == 1 and str(targets[0].get("id")) == sys.argv[2] else 1)
PY
}
EOF

cat > "$SCOPED_DIR/check-cli.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == status-import && $# -eq 2 ]] || exit 2
cp -- "$2" "$UU_STATUS_MODEL_FILE"
EOF

cat > "$SCOPED_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${!#}" >> "$SCOPED_SSH_LOG"
bash -c "${!#}"
EOF
chmod 750 "$SCOPED_DIR/status-model.sh" "$SCOPED_DIR/check-cli.sh" "$SCOPED_DIR/bin/ssh"

printf '%s\n' '{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","name":"fixture","check_status":"ok","reachable":true,"updates":{"available":6},"package_data_invalidated":true,"package_mutation_in_progress":true,"last_update":{"status":"old"}}]}' > "$SCOPED_DIR/status.json"
touch "$SCOPED_DIR/update.conf"

make_remote_ref() {
  local unit="$1" target="$2" registered_at="$3"
  cat > "$SCOPED_DIR/jobs/remote/$unit.ref" <<EOF
schema_version=1
unit=$unit
target=$target
owner_node=test-node2
owner_host=127.0.0.1
port=22
registered_at=$registered_at
status_refresh=pending
workspace=$REMOTE_DIR/$unit
EOF
  mkdir -p "$REMOTE_DIR/$unit"
  cat > "$REMOTE_DIR/$unit.state" <<EOF
unit=$unit
target=$target
state=completed
started_at=2026-10-27T12:20:48Z
finished_at=2026-10-27T12:22:31Z
exit_code=0
type=update
source=remote
interactive=false
EOF
  printf '%s\n' '{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","name":"fixture","check_status":"ok","reachable":true,"updates":{"available":0},"package_data_invalidated":false,"package_mutation_generation":1,"package_mutation_in_progress":false,"package_mutation_operation_id":"uu-op-scoped","package_checked_at":"2026-10-27T12:22:26Z","packages":[],"last_update":{"status":"success","timestamp":"2026-10-27T12:22:12Z","exit_code":0,"pending_before":6}}]}' > "$REMOTE_DIR/$unit/status.json"
}

old_unit=ultimate-updater-update-928-old
new_unit=ultimate-updater-update-928-current
foreign_unit=ultimate-updater-update-920-foreign
make_remote_ref "$old_unit" 928 2026-10-27T12:20:00Z
make_remote_ref "$new_unit" 928 2026-10-27T12:22:00Z
make_remote_ref "$foreign_unit" 920 2026-10-27T12:23:00Z

SCOPED_SSH_LOG="$SCOPED_DIR/ssh.log" PATH="$SCOPED_DIR/bin:$PATH" \
  UU_LOCAL_FILES="$SCOPED_DIR" UU_JOB_STATE_DIR="$SCOPED_DIR/jobs" \
  UU_REMOTE_JOB_STATE_DIR="$REMOTE_DIR" UU_CHECK_CLI="$SCOPED_DIR/check-cli.sh" \
  UU_STATUS_MODEL_FILE="$SCOPED_DIR/status.json" \
  "$SCOPED_DIR/ultimate-updater" status --json 928 > "$SCOPED_DIR/status-output"

grep -Fq "$new_unit" "$SCOPED_DIR/ssh.log"
if grep -Fq "$old_unit" "$SCOPED_DIR/ssh.log" || grep -Fq "$foreign_unit" "$SCOPED_DIR/ssh.log"; then
  exit 1
fi
grep -Fxq 'status_refresh=done' "$SCOPED_DIR/jobs/remote/$new_unit.ref"
grep -Fxq 'status_refresh=pending' "$SCOPED_DIR/jobs/remote/$old_unit.ref"
grep -Fxq 'status_refresh=pending' "$SCOPED_DIR/jobs/remote/$foreign_unit.ref"

python3 - "$SCOPED_DIR/status-output" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert record["id"] == "928"
assert record["last_update"]["pending_before"] == 6
assert record["package_data_invalidated"] is False
assert record["package_mutation_in_progress"] is False
PY

echo 'target-scoped status refresh tests: PASS'
