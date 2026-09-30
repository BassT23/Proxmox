#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/bin"
cp "$ROOT_DIR/ultimate-updater" "$WORK_DIR/local/ultimate-updater"
cp "$ROOT_DIR/cluster-target.sh" "$WORK_DIR/local/cluster-target.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/local/status-model.sh"
cat > "$WORK_DIR/local/update.conf" <<'EOF'
IN_HEADLESS_MODE="true"
EOF
cat > "$WORK_DIR/local/status.json" <<'EOF'
{"schema_version":1,"targets":[{"id":"host:test-node","type":"host","node":"test-node","name":"test-node","check_status":"ok","reachable":true,"updates":{"available":0}}]}
EOF
cat > "$WORK_DIR/bin/hostname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -s ]]; then printf 'test-node\n'; else printf 'test-node.example\n'; fi
EOF
chmod +x "$WORK_DIR/bin/hostname"
cat > "$WORK_DIR/local/check-updates.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" > "$CHECK_CALL_LOG"
exit 0
EOF
cat > "$WORK_DIR/local/update.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$UPDATE_CALL_LOG"
exit 0
EOF
cat > "$WORK_DIR/local/job-runner.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$JOB_CALL_LOG"
exit 0
EOF
chmod +x "$WORK_DIR/local"/{check-updates.sh,update.sh,job-runner.sh}

export PATH="$WORK_DIR/bin:$PATH"
export UU_LOCAL_FILES="$WORK_DIR/local" UU_NONINTERACTIVE=true
export CHECK_CALL_LOG="$WORK_DIR/check-call" UPDATE_CALL_LOG="$WORK_DIR/update-call" JOB_CALL_LOG="$WORK_DIR/job-call"
export UU_CLUSTER_LOCAL_NODE=test-node UU_COROSYNC_CONFIG_FILE="$WORK_DIR/no-corosync.conf"

run_cli() { UU_CHECK_JOB_EXECUTION=true bash "$WORK_DIR/local/ultimate-updater" "$@"; }

run_cli check-node local-host >/dev/null
[[ "$(<"$WORK_DIR/check-call")" == node-host ]]
run_cli check-node test-node >/dev/null
[[ "$(<"$WORK_DIR/check-call")" == node-host ]]
if run_cli check-node other-node >/dev/null 2>&1; then exit 1; fi

# Exercise the production resolver function itself with a temporary cluster
# config; no live Proxmox configuration is modified.
source "$ROOT_DIR/cluster-target.sh"
resolver=$(sed -n '/^cluster_node_resolve() {/,/^remote_node_check_via_cluster_transport() {/p' \
  "$ROOT_DIR/ultimate-updater" | sed '$d')
update_node=$(sed -n '/^run_node_update() {/,/^finish_partial_status() {/p' \
  "$ROOT_DIR/ultimate-updater" | sed '$d')
eval "$resolver"
eval "$update_node"
require_file() { [[ -f "$1" ]]; }
interactive_requested() { return 1; }
JOB_RUNNER="$WORK_DIR/local/job-runner.sh"
UPDATE_SCRIPT="$WORK_DIR/local/update.sh"
export UU_CLUSTER_LOCAL_NODE=cluster-a UU_COROSYNC_CONFIG_FILE="$WORK_DIR/corosync.conf"
cat > "$UU_COROSYNC_CONFIG_FILE" <<'EOF'
nodelist {
  node { name: cluster-a ring0_addr: 192.0.2.10 }
  node { name: cluster-b ring0_addr: 192.0.2.11 }
}
EOF
cluster_node_resolve local-host
[[ "$RESOLVED_NODE" == cluster-a && "$RESOLVED_NODE_LOCAL" == true && "$RESOLVED_NODE_HOST" == 192.0.2.10 ]]
cluster_node_resolve cluster-a
[[ "$RESOLVED_NODE_LOCAL" == true ]]
cluster_node_resolve cluster-b
[[ "$RESOLVED_NODE_LOCAL" == false && "$RESOLVED_NODE_HOST" == 192.0.2.11 ]]
if cluster_node_resolve missing-node; then exit 1; fi

export UU_CLUSTER_LOCAL_NODE=test-node UU_COROSYNC_CONFIG_FILE="$WORK_DIR/no-corosync.conf"
run_node_update local-host
grep -Fq 'start ' "$WORK_DIR/job-call"
run_node_update test-node
grep -Fq 'start ' "$WORK_DIR/job-call"

echo 'standalone local node action resolution: PASS'
