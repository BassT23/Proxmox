#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# The resolver is the same current-cluster lookup used by the API runtime
# guards.  No pvesh/qm/pct/ssh command is available in this fixture.
source "$ROOT_DIR/cluster-target.sh"
UU_CLUSTER_LOCAL_NODE=test-node
UU_CLUSTER_RESOURCES_JSON='[
  {"type":"lxc","vmid":100,"node":"test-node","name":"fixture-lxc"},
  {"type":"qemu","vmid":986,"node":"test-node","name":"fixture-vm"}
]'

cluster_target_api_identity_matches 100 lxc test-node true
if cluster_target_api_identity_matches 100 vm test-node true; then
  echo 'LXC was accepted as VM identity' >&2
  exit 1
fi
if cluster_target_api_identity_matches 100 lxc other-node true; then
  echo 'node migration was not rejected' >&2
  exit 1
fi
if cluster_target_api_identity_matches 986 vm test-node false; then
  echo 'local/remote identity mismatch was not rejected' >&2
  exit 1
fi

UU_CLUSTER_RESOURCES_JSON='[
  {"type":"qemu","vmid":986,"node":"test-node","name":"fixture-vm"},
  {"type":"qemu","vmid":986,"node":"other-node","name":"replacement"}
]'
if cluster_target_api_identity_matches 986 vm test-node true; then
  echo 'duplicate VMID was accepted' >&2
  exit 1
fi

# Exercise the production pre-dispatch identity guard.  A changed current
# resource must fail before a check/update body can be entered.
awk '
  /^api_external_identity_matches\(\)/ {copy=1}
  /^configured_ssh_port\(\)/ {if (copy) exit}
  copy {print}
' "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/identity-functions.sh"
cat > "$WORK_DIR/identity-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
source "$1/cluster-target.sh"
source "$2/identity-functions.sh"

UU_API_ACTION=check
UU_API_EXPECTED_TARGET_ID=100
UU_API_EXPECTED_TARGET_KIND=lxc
UU_API_EXPECTED_TARGET_NODE=test-node
UU_API_EXPECTED_TARGET_LOCAL=true
RESOLVED_TARGET_NODE=test-node
RESOLVED_TARGET_LOCAL=true

api_verify_resolved_identity 100 container
if api_verify_resolved_identity 100 vm; then
  echo 'runtime guard accepted a changed target type' >&2
  exit 1
fi
UU_API_EXPECTED_TARGET_NODE=other-node
if api_verify_resolved_identity 100 container; then
  echo 'runtime guard accepted a changed owner node' >&2
  exit 1
fi

cat > "$2/targets.conf" <<'EOF'
[edge]
host=198.51.100.20
port=2222
transport=ssh
user=uu
identity_file=/tmp/uu-fixture-key
EOF
LOCAL_FILES="$2"
INVENTORY_SCRIPT="$1/target-inventory.sh"
UU_API_EXPECTED_TARGET_ID=edge
UU_API_EXPECTED_TARGET_KIND=external
UU_API_EXPECTED_TARGET_NODE=""
UU_API_EXPECTED_TARGET_LOCAL=false
UU_API_EXPECTED_EXTERNAL_HOST=198.51.100.20
UU_API_EXPECTED_EXTERNAL_PORT=2222
UU_API_EXPECTED_EXTERNAL_USER=uu
UU_API_EXPECTED_EXTERNAL_IDENTITY_FILE=/tmp/uu-fixture-key
api_verify_resolved_identity edge external
UU_API_EXPECTED_EXTERNAL_HOST=198.51.100.21
if api_verify_resolved_identity edge external; then
  echo 'external configuration change was not rejected' >&2
  exit 1
fi

echo 'runtime identity guards: PASS'
HARNESS
chmod 750 "$WORK_DIR/identity-harness.sh"
bash "$WORK_DIR/identity-harness.sh" "$ROOT_DIR" "$WORK_DIR" >/dev/null

# Exercise the actual single-LXC check function with the guard present.  The
# lifecycle mock records every Proxmox action; a stopped API target must be
# reported read-only without pct start/shutdown.
awk '
  /^API_CHECK_TARGET_IDENTITY_GUARD\(\)/ {copy=1}
  copy && /^}/ {print; exit}
  copy {print}
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-guard.sh"
awk '
  /^CHECK_SINGLE_CONTAINER[[:space:]]/ {copy=1}
  copy && /^}/ {print; exit}
  copy {print}
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/single-lxc.sh"
cat > "$WORK_DIR/lxc-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail
source "$1/cluster-target.sh"
source "$2/check-guard.sh"
source "$2/single-lxc.sh"

UU_CLUSTER_LOCAL_NODE=test-node
UU_CLUSTER_RESOURCES_JSON='[{"type":"lxc","vmid":100,"node":"test-node","name":"fixture"}]'
UU_API_ACTION=check
UU_API_EXPECTED_TARGET_ID=100
UU_API_EXPECTED_TARGET_KIND=lxc
UU_API_EXPECTED_TARGET_NODE=test-node
UU_API_EXPECTED_TARGET_LOCAL=true
INITIAL_INVENTORY=true
STOPPED=true
RUNNING=true
UU_EXPLICIT_TARGET_CHECK=true
STATUS_MODEL_NODE=test-node
CALLS=""

pct() {
  case "${1:-}" in
    status) printf 'status: stopped\n' ;;
    start|shutdown) CALLS+="$1\n" ;;
  esac
}
timeout() { shift; "$@"; }
STATUS_MODEL_RECORD() { CALLS+="record:$*\n"; }
CHECK_CONTAINER_FAILURE() { return 1; }
CHECK_CONTAINER() { CALLS+="checked\n"; }
RUN_PROXMOX_CAPTURE() { CALLS+="prox:$*\n"; }
WAIT_FOR_BOOTUP_LXC() { return 0; }

CHECK_SINGLE_CONTAINER 100
[[ "$CALLS" == *'STOPPED_READ_ONLY'* ]]
[[ "$CALLS" != *'prox:pct start'* ]]
[[ "$CALLS" != *'prox:pct shutdown'* ]]

# A current type mismatch is rejected before even the guest status command.
CALLS=""
UU_API_EXPECTED_TARGET_KIND=vm
set +e
CHECK_SINGLE_CONTAINER 100
rc=$?
set -e
[[ $rc -eq 46 ]]
[[ "$CALLS" == *'API_TARGET_IDENTITY_MISMATCH'* ]]
[[ "$CALLS" != *'prox:'* ]]
HARNESS
chmod 750 "$WORK_DIR/lxc-harness.sh"
bash "$WORK_DIR/lxc-harness.sh" "$ROOT_DIR" "$WORK_DIR" >/dev/null

echo 'API target identity regression tests: PASS'
