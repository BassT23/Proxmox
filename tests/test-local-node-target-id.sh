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

# The WebUI sends the canonical status key while keeping the hostname as the
# display label. The API accepts that key and maps only the actual local node
# to the CLI's stable local-host alias.
grep -Fq 'const actionNode=host?.id||node' "$SERVER"
grep -Fq 'data-node-action="check:${esc(actionNode)}"' "$SERVER"
grep -Fq 'def node_action_target(self, node):' "$SERVER"
grep -Fq 'node = node.removeprefix("host:")' "$SERVER"
grep -Fq 'socket.gethostname().split(".", 1)[0]' "$SERVER"
grep -Fq 'return "local-host"' "$SERVER"
grep -Fq 'action_target = self.node_action_target(node)' "$SERVER"
grep -Fq '"start-check", action_target' "$SERVER"
grep -Fq '"update-node", action_target' "$SERVER"

# Cluster-wide operations retain their existing all-systems entry point.
grep -Fq '"start-check", "all-systems"' "$SERVER"

echo 'local node stable target ID tests: PASS'
