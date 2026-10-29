#!/bin/bash

# Resolve numeric Proxmox guest IDs against the local cluster inventory.
# This helper only answers "where is the guest?"; update/check policy stays in
# the existing updater and check scripts.

CLUSTER_TARGET_LOCAL_FILES="${CLUSTER_TARGET_LOCAL_FILES:-${LOCAL_FILES:-/etc/ultimate-updater}}"

cluster_target_is_id() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

cluster_target_resources_json() {
  if [[ -n "${UU_CLUSTER_RESOURCES_JSON:-}" ]]; then
    printf '%s\n' "$UU_CLUSTER_RESOURCES_JSON"
    return 0
  fi
  command -v pvesh >/dev/null 2>&1 || return 1
  pvesh get /cluster/resources --type vm --output-format json 2>/dev/null
}

cluster_target_node_host() {
  local node="$1" config="/etc/pve/corosync.conf"
  if [[ -n "${UU_CLUSTER_NODE_HOST:-}" ]]; then
    printf '%s\n' "$UU_CLUSTER_NODE_HOST"
    return 0
  fi
  if [[ -f "$config" ]]; then
    local mapped_host
    mapped_host=$(python3 - "$config" "$node" <<'PY'
import re
import sys

path, wanted = sys.argv[1:]
try:
    text = open(path, encoding="utf-8").read()
except OSError:
    raise SystemExit(0)

for block in re.findall(r"node\s*\{(.*?)\}", text, re.S):
    name = re.search(r"\bname\s*:\s*([^\s}]+)", block)
    address = re.search(r"\bring0_addr\s*:\s*([^\s}]+)", block)
    if name and address and name.group(1) == wanted:
        print(address.group(1))
        raise SystemExit(0)
PY
    )
    if [[ -n "$mapped_host" ]]; then
      printf '%s\n' "$mapped_host"
      return 0
    fi
  fi
  printf '%s\n' "$node"
}

cluster_target_local_node() {
  if [[ -n "${UU_CLUSTER_LOCAL_NODE:-}" ]]; then
    printf '%s\n' "$UU_CLUSTER_LOCAL_NODE"
    return 0
  fi
  hostname -s 2>/dev/null || hostname
}

# Sets CLUSTER_TARGET_ID, CLUSTER_TARGET_KIND, CLUSTER_TARGET_NODE,
# CLUSTER_TARGET_NAME, CLUSTER_TARGET_HOST and CLUSTER_TARGET_LOCAL. Return values:
#   0 resolved, 1 not found/unsupported inventory, 2 invalid ID,
#   4 ambiguous, 5 cluster inventory unavailable.
cluster_target_resolve() {
  local target="${1:-}" json result
  unset CLUSTER_TARGET_ID CLUSTER_TARGET_KIND CLUSTER_TARGET_NODE \
    CLUSTER_TARGET_NAME CLUSTER_TARGET_HOST CLUSTER_TARGET_LOCAL
  if ! cluster_target_is_id "$target"; then
    return 2
  fi
  json=$(cluster_target_resources_json) || return 5
  result=$(python3 -c '
import json
import sys

target = sys.argv[1]
try:
    resources = json.load(sys.stdin)
except (ValueError, OSError):
    raise SystemExit(5)

matches = []
for item in resources if isinstance(resources, list) else []:
    if not isinstance(item, dict):
        continue
    kind = item.get("type")
    if kind not in {"lxc", "qemu"}:
        continue
    raw_id = item.get("vmid", item.get("id"))
    if isinstance(raw_id, str) and "/" in raw_id:
        raw_id = raw_id.rsplit("/", 1)[-1]
    if str(raw_id) != target:
        continue
    matches.append(("container" if kind == "lxc" else "vm",
                    str(item.get("node") or ""), str(item.get("name") or "")))

if len(matches) == 0:
    raise SystemExit(1)
# Every matching Proxmox resource is an identity claim.  Even identical
# rows are ambiguous: accepting one would make a later API action depend on
# arbitrary inventory ordering.
if len(matches) != 1:
    raise SystemExit(4)
kind, node, name = matches[0]
if not node:
    raise SystemExit(5)
print("\t".join((target, kind, node, name)))
' "$target" <<< "$json") || return $?
  IFS=$'\t' read -r CLUSTER_TARGET_ID CLUSTER_TARGET_KIND CLUSTER_TARGET_NODE CLUSTER_TARGET_NAME <<< "$result"
  [[ -n "$CLUSTER_TARGET_NODE" ]] || return 5
  CLUSTER_TARGET_HOST=$(cluster_target_node_host "$CLUSTER_TARGET_NODE")
  local local_node local_ips
  local_node=$(cluster_target_local_node)
  local_ips=$(hostname -I 2>/dev/null || true)
  if [[ "${CLUSTER_TARGET_NODE,,}" == "${local_node,,}" ||
        " $local_ips " == *" $CLUSTER_TARGET_HOST "* ]]; then
    CLUSTER_TARGET_LOCAL=true
  else
    CLUSTER_TARGET_LOCAL=false
  fi
  export CLUSTER_TARGET_ID CLUSTER_TARGET_KIND CLUSTER_TARGET_NODE \
    CLUSTER_TARGET_NAME CLUSTER_TARGET_HOST CLUSTER_TARGET_LOCAL
}

cluster_target_api_identity_matches() {
  local target="$1" expected_kind="$2" expected_node="$3" expected_local="$4"
  cluster_target_resolve "$target" || return $?
  case "$expected_kind" in
    lxc|container) [[ "$CLUSTER_TARGET_KIND" == container ]] || return 46 ;;
    vm) [[ "$CLUSTER_TARGET_KIND" == vm ]] || return 46 ;;
    *) return 46 ;;
  esac
  [[ "$CLUSTER_TARGET_NODE" == "$expected_node" ]] || return 46
  # A remote owner sees the same guest as local.  The owner node remains the
  # stable identity; callers use "remote" when the controller's perspective
  # must not be compared again on the executing node.
  [[ "$expected_local" == remote || "$CLUSTER_TARGET_LOCAL" == "$expected_local" ]] || return 46
}

cluster_target_guest_name() {
  local target="${1:-}" json
  json=$(cluster_target_resources_json) || return 1
  python3 -c '
import json
import sys

target = sys.argv[1]
try:
    resources = json.load(sys.stdin)
except (ValueError, OSError):
    raise SystemExit(1)
for item in resources if isinstance(resources, list) else []:
    if not isinstance(item, dict) or item.get("type") not in {"lxc", "qemu"}:
        continue
    raw_id = item.get("vmid", item.get("id"))
    if isinstance(raw_id, str) and "/" in raw_id:
        raw_id = raw_id.rsplit("/", 1)[-1]
    if str(raw_id) == target:
        name = item.get("name")
        if isinstance(name, str) and name.strip():
            print(name.strip())
        raise SystemExit(0)
raise SystemExit(1)
' "$target" <<< "$json"
}

# Return the VMs owned by one cluster node as "VMID<TAB>name" records.  The
# caller uses this inventory to stage only the profiles that can be consumed
# by that node's run-scoped check workspace.
cluster_target_vm_inventory_for_node() {
  local wanted_node="${1:-}" json
  [[ "$wanted_node" =~ ^[A-Za-z0-9_.:-]+$ ]] || return 2
  json=$(cluster_target_resources_json) || return 1
  python3 -c '
import json
import re
import sys

wanted = sys.argv[1]
try:
    resources = json.load(sys.stdin)
except (ValueError, OSError, TypeError):
    raise SystemExit(1)

seen = set()
for item in resources if isinstance(resources, list) else []:
    if not isinstance(item, dict) or item.get("type") != "qemu":
        continue
    if str(item.get("node") or "") != wanted:
        continue
    raw_id = item.get("vmid", item.get("id"))
    if isinstance(raw_id, str) and "/" in raw_id:
        raw_id = raw_id.rsplit("/", 1)[-1]
    vmid = str(raw_id or "")
    if not re.fullmatch(r"[0-9]+", vmid) or vmid in seen:
        continue
    seen.add(vmid)
    name = str(item.get("name") or vmid).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print(f"{vmid}\t{name}")
' "$wanted_node" <<< "$json"
}

# Sources copied into a remote check workspace must be ordinary, readable
# files owned by root or by the invoking user, and must not be writable by the
# group or others.  In particular, a dangling or ordinary symlink is never
# accepted as a profile/configuration source.
cluster_target_secure_stage_file() {
  local file="${1:-}" permissions owner current_owner
  [[ -f "$file" && ! -L "$file" ]] || return 1
  permissions=$(stat -c '%A' -- "$file" 2>/dev/null) || return 1
  [[ "${permissions:5:1}" != w && "${permissions:8:1}" != w ]] || return 1
  owner=$(stat -c '%u' -- "$file" 2>/dev/null) || return 1
  current_owner=$(id -u 2>/dev/null) || return 1
  [[ "$owner" == 0 || "$owner" == "$current_owner" ]]
}

# Code helpers are not credential material, but they still must be regular
# files owned by root or the invoking user.  Repository checkouts may carry a
# group-writable mode from the worker's shared workspace; the remote copy is
# still placed in the private run-scoped workspace and never followed through
# a symlink.
cluster_target_stageable_helper() {
  local file="${1:-}" owner current_owner
  [[ -f "$file" && ! -L "$file" ]] || return 1
  owner=$(stat -c '%u' -- "$file" 2>/dev/null) || return 1
  current_owner=$(id -u 2>/dev/null) || return 1
  [[ "$owner" == 0 || "$owner" == "$current_owner" ]]
}

# Validate the complete data-only Internal SSH file with the existing parser,
# then write only VM sections for the selected node.  Node/LXC/foreign-VM
# sections never cross the remote-check boundary.
cluster_target_write_vm_ssh_config() {
  local source="${1:-}" output="${2:-}" vm_id section key found
  shift 2 || return 2
  [[ -n "$output" && -f "$output" && ! -L "$output" ]] || return 1
  if [[ -L "$source" || ( -e "$source" && ! -f "$source" ) ]]; then
    return 1
  fi
  if [[ -e "$source" ]]; then
    cluster_target_secure_stage_file "$source" || return 1
    declare -F INTERNAL_SSH_LOAD >/dev/null 2>&1 || return 1
    INTERNAL_SSH_LOAD "$source" || return 1
  else
    INTERNAL_SSH_VALUES=()
  fi
  {
    printf 'schema_version=1\n'
    for vm_id in "$@"; do
      section="vm:$vm_id"
      found=false
      for key in host user port identity_file enabled; do
        if [[ -n "${INTERNAL_SSH_VALUES[$section|$key]+x}" ]]; then
          found=true
          break
        fi
      done
      [[ "$found" == true ]] || continue
      printf '[%s]\n' "$section"
      for key in host user port identity_file enabled; do
        if [[ -n "${INTERNAL_SSH_VALUES[$section|$key]+x}" ]]; then
          printf '%s=%s\n' "$key" "${INTERNAL_SSH_VALUES[$section|$key]}"
        fi
      done
    done
  } > "$output" || return 1
  chmod 600 -- "$output" || return 1
}

cluster_target_resolve_cli() {
  local target="${1:-}"
  cluster_target_resolve "$target" || {
    case "$?" in
      1) printf 'Target %s not found in Proxmox cluster.\n' "$target" >&2 ;;
      2) printf 'Target ID must be numeric: %s\n' "$target" >&2 ;;
      4) printf 'Target ID %s is ambiguous across the cluster.\n' "$target" >&2 ;;
      *) printf 'Could not read the Proxmox cluster inventory.\n' >&2 ;;
    esac
    return 1
  }
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$CLUSTER_TARGET_ID" \
    "$CLUSTER_TARGET_KIND" "$CLUSTER_TARGET_NODE" "$CLUSTER_TARGET_NAME" \
    "$CLUSTER_TARGET_HOST" "$CLUSTER_TARGET_LOCAL"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    resolve)
      [[ $# -eq 2 ]] || { printf 'Usage: %s resolve VMID\n' "$0" >&2; exit 2; }
      cluster_target_resolve_cli "$2"
      ;;
    *)
      printf 'Usage: %s resolve VMID\n' "$0" >&2
      exit 2
      ;;
  esac
fi
