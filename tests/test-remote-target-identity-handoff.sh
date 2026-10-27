#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
REMOTE_STATUS="$WORK_DIR/remote-status.json"
REMOTE_STATE="$WORK_DIR/remote.state"
IMPORT_LOG="$WORK_DIR/import.log"
IMPORT_COPY="$WORK_DIR/imported.json"
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"

write_controller_status() {
  printf '%s\n' '{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","name":"uu-e2e-remote","check_status":"ok","reachable":true,"updates":{"available":0},"package_checked_at":"2026-10-27T05:00:00Z","package_data_invalidated":false,"package_mutation_generation":1,"package_mutation_in_progress":false}]}' > "$WORK_DIR/status.json"
}

write_remote_state() {
  cat > "$REMOTE_STATE" <<'STATE'
unit=ultimate-updater-update-928-identity
target=928
state=completed
started_at=2026-10-27T05:00:00Z
finished_at=2026-10-27T05:00:10Z
exit_code=0
type=update
source=remote
interactive=false
STATE
}

write_remote_ref() {
  cat > "$WORK_DIR/jobs/remote/ultimate-updater-update-928-identity.ref" <<EOF
schema_version=1
unit=ultimate-updater-update-928-identity
target=928
owner_node=Proxmox-Test-2
owner_host=127.0.0.1
port=22
registered_at=2026-10-27T05:00:00Z
status_refresh=pending
workspace=/tmp/ultimate-updater-update-node-1-2-3
EOF
}

cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == status-import && $# -eq 2 ]] || exit 2
printf '%s\n' "$2" >> "$IMPORT_LOG"
cp -- "$2" "$IMPORT_COPY"
cp -- "$2" "$UU_STATUS_MODEL_FILE"
EOF
chmod 750 "$WORK_DIR/check.sh"

cat > "$WORK_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
command=${!#}
case "$command" in
  *'.state'*) cat "$REMOTE_STATE" ;;
  *'status.json'*) cat "$REMOTE_STATUS" ;;
  *'post-update-status.rc'*) printf '0\n' ;;
  *'rm -rf'*) : ;;
  *) printf 'unexpected fake remote command\n' >&2; exit 1 ;;
esac
EOF
chmod 750 "$WORK_DIR/bin/ssh"
export PATH="$WORK_DIR/bin:$PATH"

write_controller_status
write_remote_state
write_remote_ref

cat > "$REMOTE_STATUS" <<'JSON'
{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","name":"uu-e2e-remote","os":"Debian","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"package_checked_at":"2026-10-27T05:00:10Z","package_data_invalidated":false,"package_mutation_generation":2,"package_mutation_operation_id":"uu-op-identity-928-20261027","package_mutation_in_progress":false}]}
JSON

run_status() {
  UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" \
  UU_LOCAL_FILES="$WORK_DIR" \
  UU_CHECK_CLI="$WORK_DIR/check.sh" \
  UU_STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  UU_STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh" \
  REMOTE_STATE="$REMOTE_STATE" REMOTE_STATUS="$REMOTE_STATUS" IMPORT_LOG="$IMPORT_LOG" IMPORT_COPY="$IMPORT_COPY" \
    "$ROOT_DIR/job-runner.sh" list >/dev/null
}

run_status
grep -Fxq 'status_refresh=done' "$WORK_DIR/jobs/remote/ultimate-updater-update-928-identity.ref"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = json.load(open(sys.argv[1], encoding="utf-8"))["targets"]
assert [item["id"] for item in targets] == ["928"]
item = targets[0]
assert (item["id"], item["type"], item["node"], item["name"]) == (
    "928", "lxc", "Proxmox-Test-2", "uu-e2e-remote"
)
assert item["package_data_invalidated"] is False
assert item["package_mutation_in_progress"] is False
assert item["package_mutation_generation"] == 2
assert item["package_mutation_operation_id"] == "uu-op-identity-928-20261027"
PY
python3 - "$IMPORT_COPY" <<'PY'
import json
import sys

imported = json.load(open(sys.argv[1], encoding="utf-8"))
assert [item["id"] for item in imported["targets"]] == ["928"]
PY

# A contaminated worker artifact is rejected before status-import. The old
# implementation validated that 928 existed but then imported the whole file,
# allowing a foreign 922 record to reach the identity gate.
write_controller_status
printf '%s\n' '{"schema_version":1,"targets":[{"id":"928","type":"lxc","node":"Proxmox-Test-2","name":"uu-e2e-remote","os":"Debian","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false},{"id":"922","type":"vm","node":"Proxmox-Test-1","name":"foreign","os":"Ubuntu","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false}]}' > "$REMOTE_STATUS"
write_remote_ref
rm -f "$WORK_DIR/jobs/remote/ultimate-updater-update-928-identity.cache"
: > "$IMPORT_LOG"
run_status 2>"$WORK_DIR/contaminated.err"
grep -Fxq 'status_refresh=pending' "$WORK_DIR/jobs/remote/ultimate-updater-update-928-identity.ref"
[[ ! -s "$IMPORT_LOG" ]]
grep -Fq 'Remote post-update status refresh failed for 928' "$WORK_DIR/contaminated.err"
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys

targets = json.load(open(sys.argv[1], encoding="utf-8"))["targets"]
assert [item["id"] for item in targets] == ["928"]
PY

# The status model's existing identity gate remains fail-closed for a direct
# type mismatch and cannot turn it into a successful import.
printf '%s\n' '{"schema_version":1,"targets":[{"id":"922","type":"lxc","node":"Proxmox-Test-1"}]}' > "$WORK_DIR/mismatch-status.json"
printf '%s\n' '{"schema_version":1,"targets":[{"id":"922","type":"vm","node":"Proxmox-Test-1"}]}' > "$WORK_DIR/mismatch-artifact.json"
cp -- "$WORK_DIR/mismatch-status.json" "$WORK_DIR/mismatch-before.json"
if STATUS_MODEL_FILE="$WORK_DIR/mismatch-status.json" STATUS_MODEL_RECORD_FILE="$WORK_DIR/mismatch.records" \
  STATUS_MODEL_GENERATION_FILE="$WORK_DIR/mismatch.generations" \
  bash -c 'source "$1/status-model.sh"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE "$2"; STATUS_MODEL_FINISH' \
  _ "$ROOT_DIR" "$WORK_DIR/mismatch-artifact.json" >"$WORK_DIR/mismatch.out" 2>"$WORK_DIR/mismatch.err"; then
  printf 'identity mismatch was accepted\n' >&2
  exit 1
fi
grep -Fq 'target identity mismatch for 922: type' "$WORK_DIR/mismatch.err"
cmp -s "$WORK_DIR/mismatch-status.json" "$WORK_DIR/mismatch-before.json"

echo 'remote target identity handback tests: PASS'
