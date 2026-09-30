#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
cp "${JOB_RUNNER_SOURCE:-$ROOT_DIR/job-runner.sh}" "$WORK_DIR/local/job-runner.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"
cp "$ROOT_DIR/internal-ssh.sh" "$WORK_DIR/local/internal-ssh.sh"
cp "$ROOT_DIR/ultimate-updater" "$WORK_DIR/local/ultimate-updater"
chmod 755 "$WORK_DIR/local/job-runner.sh" "$WORK_DIR/local/ultimate-updater"
touch "$WORK_DIR/test-identity"

cat > "$WORK_DIR/local/internal-ssh.conf" <<EOF
schema_version=1
[node:node2]
host=10.0.0.2
user=root
port=2222
identity_file=$WORK_DIR/test-identity
EOF

cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"ok","reachable":true}
]}
JSON
cat > "$WORK_DIR/remote-status.json" <<'JSON'
{"schema_version":1,"targets":[
  {"id":"host:node2","type":"host","node":"node2","name":"node2","os":"Proxmox","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"last_update":{"status":"success","timestamp":"2026-09-23T10:00:01Z","exit_code":0}},
  {"id":"200","type":"vm","node":"node2","name":"vm-200","os":"Debian","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false,"last_update":{"status":"success","timestamp":"2026-09-23T10:00:02Z","exit_code":0}},
  {"id":"201","type":"lxc","node":"node2","name":"ct-201","os":"Debian","check_status":"error","reachable":true,"updates":{"available":null},"reboot_required":false,"last_update":{"status":"failed","timestamp":"2026-09-23T10:00:03Z","exit_code":42}},
  {"id":"999","type":"vm","node":"node3","name":"foreign","os":"Debian","check_status":"ok","reachable":true,"updates":{"available":0},"reboot_required":false}
]}
JSON
printf '0\n' > "$WORK_DIR/post-update-status.rc"

cat > "$WORK_DIR/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
printf '%s\n' "$args" >> "$SSH_LOG"
[[ "$args" == *'-p 2222'* && "$args" == *'-i '* && "$args" == *' -o IdentitiesOnly=yes '* && "$args" == *'root@10.0.0.2'* ]] || {
  printf 'plain SSH policy rejected: %s\n' "$args" >&2
  exit 75
}
command="${!#}"
case "$command" in
  *'.state'*)
    printf 'schema_version=1\nunit=ultimate-updater-update-node-node2-test\ntarget=node-node2\nstate=completed\nstarted_at=2026-09-23T10:00:00Z\nfinished_at=2026-09-23T10:00:04Z\nexit_code=0\ntype=update\nsource=remote\ninteractive=false\n'
    ;;
  *'status.json'*) cat "$REMOTE_STATUS" ;;
  *'post-update-status.rc'*) cat "$REMOTE_RC" ;;
  *'rm -rf'*) : ;;
  *) : ;;
esac
SSH
chmod 755 "$WORK_DIR/bin/ssh"

export PATH="$WORK_DIR/bin:$PATH"
export SSH_LOG="$WORK_DIR/ssh.log" REMOTE_STATUS="$WORK_DIR/remote-status.json" REMOTE_RC="$WORK_DIR/post-update-status.rc"

# Prove the forward path resolves the same configured node transport.
sed -n '/^resolve_remote_node_transport() {/,/^cluster_node_resolve() {/p' \
  "$ROOT_DIR/ultimate-updater" | sed '$d' > "$WORK_DIR/forward.sh"
LOCAL_FILES="$WORK_DIR/local" INTERNAL_SSH_CONFIG_FILE="$WORK_DIR/local/internal-ssh.conf" \
  bash -c 'source "$1"; source "$2"; configured_ssh_port() { printf "22\n"; }; resolve_remote_node_transport node2 node-default; ssh -q "${REMOTE_NODE_ARGS[@]}" -p "$REMOTE_NODE_PORT" "$REMOTE_NODE_USER@$REMOTE_NODE_HOST" true' \
  _ "$WORK_DIR/local/internal-ssh.sh" "$WORK_DIR/forward.sh"

# A plain handback connection is intentionally rejected by the fixture.
if "$WORK_DIR/bin/ssh" -q -o BatchMode=yes -o ConnectTimeout=5 -p 22 remote-node true; then
  echo 'plain SSH unexpectedly accepted' >&2
  exit 1
fi

UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
  UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh" \
  UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater" \
  UU_INTERNAL_SSH_FILE="$WORK_DIR/local/internal-ssh.sh" \
  UU_INTERNAL_SSH_CONFIG_FILE="$WORK_DIR/local/internal-ssh.conf" \
  "$WORK_DIR/local/job-runner.sh" record-remote \
  ultimate-updater-update-node-node2-test node-node2 node2 remote-node 22 \
  /tmp/ultimate-updater-update-node-1-2-3

UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
  UU_STATUS_MODEL_FILE="$WORK_DIR/local/status.json" \
  UU_STATUS_MODEL_SCRIPT="$WORK_DIR/local/status-model.sh" \
  UU_CHECK_CLI="$WORK_DIR/local/ultimate-updater" \
  UU_INTERNAL_SSH_FILE="$WORK_DIR/local/internal-ssh.sh" \
  UU_INTERNAL_SSH_CONFIG_FILE="$WORK_DIR/local/internal-ssh.conf" \
  UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" \
  "$WORK_DIR/local/job-runner.sh" list >/dev/null

python3 - "$WORK_DIR/local/status.json" "$WORK_DIR/ssh.log" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
targets = {item["id"]: item for item in payload["targets"]}
assert targets["host:node2"]["last_update"]["status"] == "success"
assert targets["200"]["last_update"]["status"] == "success"
assert targets["201"]["last_update"] == {
    "status": "failed", "timestamp": "2026-09-23T10:00:03Z", "exit_code": 42
}
assert "999" not in targets
lines = open(sys.argv[2], encoding="utf-8").read().splitlines()
configured = [line for line in lines if "-p 2222" in line]
assert len(configured) >= 5
assert all("root@10.0.0.2" in line for line in configured)
assert all("-i " in line and "IdentitiesOnly=yes" in line for line in configured)
assert any("-p 22 remote-node" in line for line in lines)
PY

echo 'configured Internal-SSH remote handback regression: PASS'
