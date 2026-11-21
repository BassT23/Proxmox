#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2317
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/local" "$WORK_DIR/VMs"

cat > "$WORK_DIR/bin/hostname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -s) [[ "${UU_TEST_NO_HOSTNAME:-false}" == true ]] && exit 1; printf 'node-a\n' ;;
  -i) printf '192.0.2.99 192.0.2.10\n' ;;
  -I) printf '192.0.2.99 192.0.2.10\n' ;;
  -f) printf 'node-a.example\n' ;;
  *) [[ "${UU_TEST_NO_HOSTNAME:-false}" == true ]] && exit 1; printf 'node-a\n' ;;
esac
SH
chmod 755 "$WORK_DIR/bin/hostname"

cat > "$WORK_DIR/corosync.conf" <<'EOF'
nodelist {
  node {
    name: node-a
    ring0_addr: 192.0.2.10
  }
  node {
    name: node-b
    ring0_addr: 192.0.2.11
  }
}
EOF
cat > "$WORK_DIR/internal-ssh.conf" <<'EOF'
schema_version=1
[node:node-a]
host=127.0.0.1
[node:node-b]
host=127.0.0.1
EOF

export PATH="$WORK_DIR/bin:$PATH"
export UU_COROSYNC_CONFIG_FILE="$WORK_DIR/corosync.conf"
export UU_CLUSTER_LOCAL_NODE=""
export CLUSTER_TARGET_LOCAL_FILES="$WORK_DIR/local"
export INTERNAL_SSH_CONFIG_FILE="$WORK_DIR/internal-ssh.conf"
export UU_CLUSTER_RESOURCES_JSON='[{"type":"lxc","vmid":101,"node":"node-a","name":"local-ct"},{"type":"qemu","vmid":102,"node":"node-b","name":"remote-vm"}]'

# A local address is deliberately not the first hostname -i result.  The
# canonical Corosync node name must still decide locality.
# shellcheck disable=SC1091
source "$ROOT_DIR/cluster-target.sh"
[[ "$(cluster_target_node_for_host 192.0.2.10)" == node-a ]]
[[ "$(cluster_target_node_for_host 192.0.2.11)" == node-b ]]
cluster_target_node_is_local node-a
if cluster_target_node_is_local node-b; then exit 1; fi
cluster_target_resolve 101
[[ "$CLUSTER_TARGET_NODE" == node-a && "$CLUSTER_TARGET_LOCAL" == true ]]
cluster_target_resolve 102
[[ "$CLUSTER_TARGET_NODE" == node-b && "$CLUSTER_TARGET_LOCAL" == false ]]

# SSH overrides change only the transport address, never the node identity.
# shellcheck disable=SC1091
source "$ROOT_DIR/internal-ssh.sh"
INTERNAL_SSH_RESOLVE_NODE node-a 192.0.2.10 22
[[ "$INTERNAL_SSH_HOST" == 127.0.0.1 ]]
cluster_target_node_is_local node-a
INTERNAL_SSH_RESOLVE_NODE node-b 192.0.2.11 22
[[ "$INTERNAL_SSH_HOST" == 127.0.0.1 ]]
if cluster_target_node_is_local node-b; then exit 1; fi

# An address without a Corosync mapping, and an ambiguous mapping, must not
# be promoted to a target identity.
unset UU_COROSYNC_CONFIG_FILE
if cluster_target_node_for_host 192.0.2.10; then exit 1; fi
cat > "$WORK_DIR/ambiguous-corosync.conf" <<'EOF'
nodelist {
  node {
    name: node-a
    ring0_addr: 192.0.2.10
  }
  node {
    name: node-b
    ring0_addr: 192.0.2.10
  }
}
EOF
export UU_COROSYNC_CONFIG_FILE="$WORK_DIR/ambiguous-corosync.conf"
if cluster_target_node_for_host 192.0.2.10; then exit 1; fi
export UU_COROSYNC_CONFIG_FILE="$WORK_DIR/corosync.conf"

# The standalone CLI resolver uses the same name-only locality rule.
sed -n '/^cluster_node_resolve() {/,/^remote_node_check_via_cluster_transport() {/p' \
  "$ROOT_DIR/ultimate-updater" | sed '$d' > "$WORK_DIR/cluster-node-resolve.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/cluster-node-resolve.sh"
cluster_node_resolve node-a
[[ "$RESOLVED_NODE_LOCAL" == true ]]
cluster_node_resolve node-b
[[ "$RESOLVED_NODE_LOCAL" == false ]]

# The global host-check dispatcher receives the canonical name, not the ring
# address, so an SSH alias cannot turn the local node into a remote dispatch.
sed -n '/^HOST_CHECK_START () {/,/^# Host Check/p' "$ROOT_DIR/check-updates.sh" \
  | sed '$d' > "$WORK_DIR/host-check-start.sh"
sed -n '/^CLUSTER_HOST_NODE () {/,/^# Host Check Start/p' "$ROOT_DIR/check-updates.sh" \
  | sed '$d' > "$WORK_DIR/host-node-helpers.sh"
sed -n '/^HOST_IS_LOCAL () {/,/^}/p' "$ROOT_DIR/check-updates.sh" >> "$WORK_DIR/host-node-helpers.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/host-node-helpers.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/host-check-start.sh"
HOSTS='192.0.2.10 192.0.2.11'
USE_INTERNAL_TARGET_SELECTION=false
WITH_HOST=true
WITH_LXC=false
WITH_VM=false
CHECK_FAILURE=0
checked_hosts=()
REMOTE_TRACE() { :; }
CHECK_HOST_ITSELF() { checked_hosts+=("local:$HOST"); }
CHECK_HOST() { checked_hosts+=("remote:$1"); }
HOST_CHECK_START
[[ "${checked_hosts[*]}" == 'local:192.0.2.10 remote:192.0.2.11' ]]

# The update dispatcher resolves the canonical node before applying the SSH
# override.  The worker receives the alias as transport, but UPDATE_HOST sees
# the same node identity for both paths.
sed -n '/^HOST_UPDATE_START () {/,/^# Host Update/p' "$ROOT_DIR/update.sh" \
  | sed '$d' > "$WORK_DIR/host-update-start.sh"
update_calls=()
INTERNAL_SSH_RESOLVE_NODE() {
  INTERNAL_SSH_HOST=127.0.0.1
  INTERNAL_SSH_PORT="$3"
  INTERNAL_SSH_ENABLED=true
}
INTERNAL_SSH_USE_IDENTITY() { :; }
ssh() { return 0; }
UPDATE_HOST() { update_calls+=("$HOST_NODE|$1"); }
HOSTS='192.0.2.10 192.0.2.11'
RICM=false
SSH_PORT=22
LOCAL_FILES="$WORK_DIR/local"
UPDATE_FAILURE=false
USE_INTERNAL_TARGET_SELECTION=false
# shellcheck disable=SC1091
source "$WORK_DIR/host-update-start.sh"
HOST_UPDATE_START
[[ "${update_calls[*]}" == 'node-a|127.0.0.1 node-b|127.0.0.1' ]]

# UPDATE_HOST must use HOST_NODE even when the transport endpoint is an alias
# that looks local.  This checks both reservation branches without executing
# SSH, package managers, or any cluster action.
sed -n '/^UPDATE_HOST () {/,/^# shellcheck disable=SC2015/p' "$ROOT_DIR/update.sh" \
  | sed '$d' > "$WORK_DIR/update-host.sh"
REQUIRE_PACKAGE_DATA_INVALIDATION() { :; }
STATUS_MODEL_NEW_OPERATION_ID() {
  printf 'uu-op-fixture\n' | tee -a "$WORK_DIR/events"
}
MARK_PACKAGE_DATA_INVALIDATED() { printf 'invalidate|%s|%s|%s\n' "$1" "$3" "$4" >> "$WORK_DIR/events"; }
MARK_PACKAGE_DATA_MUTATION_COMPLETE() { printf 'complete|%s|%s|%s\n' "$1" "$3" "$4" >> "$WORK_DIR/events"; }
EFFECTIVE_HEADLESS() { return 0; }
ssh() { return 0; }
scp() { return 0; }
LOCAL_FILES="$WORK_DIR/local"
SCRIPT_DIR="$ROOT_DIR"
SSH_PORT=22
WELCOME_SCREEN=false
UPDATE_FAILURE=false
USE_INTERNAL_TARGET_SELECTION=false
touch "$LOCAL_FILES/update.conf" "$LOCAL_FILES/product-metadata.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/update-host.sh"

: > "$WORK_DIR/events"
HOST_NODE='node-a'
UPDATE_HOST 127.0.0.1
[[ ! -s "$WORK_DIR/events" ]]

: > "$WORK_DIR/events"
HOST_NODE='node-b'
UPDATE_HOST 127.0.0.1
grep -Fq 'uu-op-fixture' "$WORK_DIR/events"
grep -Fq 'invalidate|host:node-b|node-b|uu-op-fixture' "$WORK_DIR/events"
grep -Fq 'complete|host:node-b|node-b|uu-op-fixture' "$WORK_DIR/events"

# Optional host probes also use the canonical node identity while retaining
# the supplied transport endpoint for remote execution.
sed -n '/^API_UPDATE_GUEST_OPTIONAL_PROBE() {/,/^API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH()/p' \
  "$ROOT_DIR/update.sh" | sed '$d' > "$WORK_DIR/api-probe.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/api-probe.sh"
RUN_SSH_COMMAND() { printf 'remote\n' >> "$WORK_DIR/probe-events"; printf 'safe\n'; }
EXTRA_GLOBAL=false
EXTRA_IN_HEADLESS=false
UU_API_EXPECTED_TARGET_NODE='node-a'
: > "$WORK_DIR/probe-events"
if API_UPDATE_GUEST_OPTIONAL_PROBE 127.0.0.1 host sh; then
  exit 1
else
  [[ "$?" -eq 1 ]]
fi
[[ ! -s "$WORK_DIR/probe-events" ]]
UU_API_EXPECTED_TARGET_NODE='node-b'
if API_UPDATE_GUEST_OPTIONAL_PROBE 127.0.0.1 host sh; then
  exit 1
else
  [[ "$?" -eq 1 ]]
fi
grep -Fxq remote "$WORK_DIR/probe-events"

# An unavailable local identity is not silently treated as local or remote.
export UU_TEST_NO_HOSTNAME=true
if cluster_target_node_is_local node-a; then
  exit 1
else
  no_identity_rc=$?
fi
[[ "$no_identity_rc" -eq 2 ]]
if HOST_IS_LOCAL node-a; then
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
if cluster_target_resolve 101; then exit 1; fi

echo 'node identity routing tests: PASS'
