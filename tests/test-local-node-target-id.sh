#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/ultimate-updater"
SERVER="$ROOT_DIR/web-ui/server.py"

# The stable local target ID must be accepted by the CLI resolver and mapped
# to the real Corosync node name before local/remote dispatch decisions.
grep -Fq "if [[ \"\$wanted\" == local-host ]]; then" "$CLI"
grep -Fq "wanted=\"\$local_node\"" "$CLI"
grep -Fq 'run_node_check()' "$CLI"
grep -Fq 'run_node_update()' "$CLI"

# The API keeps the displayed hostname for presentation but normalizes local
# node actions to the stable target ID before starting either action.
grep -Fq 'def node_action_target(self, node):' "$SERVER"
grep -Fq 'node = self.node_action_target(node)' "$SERVER"
grep -Fq 'action_target = self.node_action_target(node)' "$SERVER"
grep -Fq '"start-check", action_target' "$SERVER"
grep -Fq '"update-node", action_target' "$SERVER"

# Cluster-wide operations retain their existing all-systems entry point.
grep -Fq '"start-check", "all-systems"' "$SERVER"

echo 'local node stable target ID tests: PASS'
