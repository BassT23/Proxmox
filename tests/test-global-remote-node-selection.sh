#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2329 # Extracted/sourced test fixture intentionally uses globals and callback functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

grep -Fq '"${UU_GLOBAL_CHECK:-false}" == true' "$ROOT_DIR/check-updates.sh"
grep -Fq 'MODE" =~ Cluster || "${UU_GLOBAL_CHECK:-false}" == true' "$ROOT_DIR/check-updates.sh"

sed -n '/^HOST_CHECK_START () {/,/^# Host Check/p' "$ROOT_DIR/check-updates.sh" \
  | sed '$d' > "$WORK_DIR/host-loop.sh"
REMOTE_TRACE() { :; }
source "$WORK_DIR/host-loop.sh"

HOSTS='node1 node2 node3'
USE_INTERNAL_TARGET_SELECTION=true
WITH_HOST=true
WITH_LXC=true
WITH_VM=true
CHECK_FAILURE=0
checked_hosts=()
HOST_IS_LOCAL() { return 1; }
CLUSTER_HOST_NODE() { printf '%s\n' "$1"; }
TARGET_SELECTION_ALLOWS() { [[ "$2" == host:node2 ]]; }
TARGET_SELECTION_GUEST_ONLY_REQUIRES_HOST() { return 1; }
TARGET_SELECTION_HAS_HOST_ONLY() { return 0; }
TARGET_SELECTION_HAS_GUEST_ONLY() { return 1; }
CHECK_HOST() { checked_hosts+=("$1"); return 0; }
HOST_CHECK_START
[[ "${checked_hosts[*]}" == node2 ]]
[[ "$CHECK_FAILURE" -eq 0 ]]

# A host-only selection must not enter the guest loops.
grep -Fq 'UU_CHECK_SCOPE=host' "$ROOT_DIR/check-updates.sh"

# Multiple node-only rules dispatch both selected nodes and no others.
checked_hosts=()
TARGET_SELECTION_ALLOWS() { [[ "$2" == host:node1 || "$2" == host:node2 ]]; }
HOST_CHECK_START
[[ "${checked_hosts[*]}" == 'node1 node2' ]]

# With no host-only rules, a host exclusion keeps the other nodes eligible.
checked_hosts=()
TARGET_SELECTION_ALLOWS() { [[ "$2" != host:node2 ]]; }
TARGET_SELECTION_HAS_HOST_ONLY() { return 1; }
HOST_CHECK_START
[[ "${checked_hosts[*]}" == 'node1 node3' ]]

# Mixed host/guest-only selection still dispatches the selected host through
# the normal path; guest selection remains owned by the existing guest loops.
checked_hosts=()
TARGET_SELECTION_ALLOWS() { [[ "$2" == host:node2 ]]; }
TARGET_SELECTION_HAS_HOST_ONLY() { return 0; }
TARGET_SELECTION_HAS_GUEST_ONLY() { return 0; }
HOST_CHECK_START
[[ "${checked_hosts[*]}" == node2 ]]

cat > "$WORK_DIR/target-selection.json" <<'JSON'
{"schema_version":1,"check":{"host:node1":"exclude","host:node2":"only","guest:211":"exclude"}}
JSON
USE_INTERNAL_TARGET_SELECTION=true UU_TARGET_SELECTION_FILE="$WORK_DIR/target-selection.json" \
  bash -c 'source "$1"; ! TARGET_SELECTION_GUEST_ONLY_REQUIRES_HOST check host:node1' _ "$ROOT_DIR/target-selection.sh"

cat > "$WORK_DIR/target-selection.json" <<'JSON'
{"schema_version":1,"check":{"host:node1":"exclude","host:node2":"only","guest:211":"only"}}
JSON
USE_INTERNAL_TARGET_SELECTION=true UU_TARGET_SELECTION_FILE="$WORK_DIR/target-selection.json" \
  bash -c 'source "$1"; TARGET_SELECTION_GUEST_ONLY_REQUIRES_HOST check host:node1' _ "$ROOT_DIR/target-selection.sh"

# A local host's guest scan changes the shared guest eligibility variable.
# Host selection must continue to use the host-scoped snapshot captured by
# HOST_CHECK_START, otherwise subsequent remote hosts are silently skipped.
checked_hosts=()
HOST_IS_LOCAL() { [[ "$1" == node1 ]]; }
CHECK_HOST_ITSELF() { checked_hosts+=("local:$HOST"); }
CONTAINER_CHECK_START() { UU_FILTER_ELIGIBLE_IDS='guest:211'; }
VM_CHECK_START() { UU_FILTER_ELIGIBLE_IDS='guest:212'; }
TARGET_SELECTION_ALLOWS() { [[ " $3 " == *" $2 "* ]]; }
TARGET_SELECTION_GUEST_ONLY_REQUIRES_HOST() { return 1; }
TARGET_SELECTION_HAS_HOST_ONLY() { return 1; }
TARGET_SELECTION_HAS_GUEST_ONLY() { return 1; }
CHECK_HOST() { checked_hosts+=("remote:$1"); return 0; }
HOSTS='node1 node2 node3'
UU_FILTER_ELIGIBLE_IDS='stale-value'
HOST_CHECK_START
[[ "${checked_hosts[*]}" == 'local:node1 remote:node2 remote:node3' ]]

echo 'global remote-node selection tests: PASS'
