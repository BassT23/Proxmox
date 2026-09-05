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
if len({match for match in matches}) != 1:
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
