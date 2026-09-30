#!/usr/bin/env bash
set -euo pipefail

# Read-only audit helper. Run it on a positively identified TEST controller.
# It never starts, stops, changes or deletes guests.

expected_cluster='Test-Cluster'
[[ "$(hostname -s)" == 'Proxmox-Test-1' ]] || {
  printf 'Refusing audit: run on Proxmox-Test-1, got %s\n' "$(hostname -s)" >&2
  exit 2
}

cluster=$(pvecm status | awk -F': ' '/^Name:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
[[ "$cluster" == "$expected_cluster" ]] || {
  printf 'Refusing audit: unexpected cluster %s\n' "$cluster" >&2
  exit 2
}

membership=$(pvecm nodes)
for node in Proxmox-Test-1 Proxmox-Test-2 Proxmox-Test-3; do
  grep -Fq "$node" <<<"$membership" || {
    printf 'Refusing audit: missing expected node %s\n' "$node" >&2
    exit 2
  }
done
for address in 192.168.10.101 192.168.10.102 192.168.10.103; do
  pvecm status | grep -Fq "$address" || {
    printf 'Refusing audit: missing expected address %s\n' "$address" >&2
    exit 2
  }
done

printf 'cluster=%s\n' "$cluster"
pvecm status | awk '/^(Nodes|Quorate):|^Membership information|^ *0x/{print}'
printf '\n9xx fixtures:\n'
pvesh get /cluster/resources --type vm --output-format json | python3 -c '
import json, sys
for item in json.load(sys.stdin):
    if 900 <= int(item.get("vmid", 0)) <= 999:
        print("{vmid} {type} {node} {status} {name} tags={tags}".format(
            vmid=item.get("vmid"), type=item.get("type"), node=item.get("node"),
            status=item.get("status"), name=item.get("name", ""), tags=item.get("tags", "")))
'
printf '\nstorage:\n'
pvesm status
printf '\nactive updater jobs:\n'
find /var/lib/ultimate-updater/jobs -maxdepth 1 -name '*.state' -type f -print0 |
  xargs -0r grep -H '^state=\(running\|starting\)$' || true
