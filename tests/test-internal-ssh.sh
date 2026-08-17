#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
CONFIG="$WORK_DIR/internal-ssh.conf"
cat > "$CONFIG" <<'EOF'
schema_version=1

[node:node3]
host=192.0.2.30
user=root
port=2222
identity_file=/root/.ssh/test-key
enabled=true

[vm:155]
host=192.0.2.155
user=admin
port=2200
enabled=true
EOF

# shellcheck disable=SC1091
source "$ROOT_DIR/internal-ssh.sh"
INTERNAL_SSH_CONFIG_FILE="$CONFIG"
INTERNAL_SSH_RESOLVE_NODE node3 cluster-name 22
[[ "$INTERNAL_SSH_HOST" == 192.0.2.30 && "$INTERNAL_SSH_USER" == root && "$INTERNAL_SSH_PORT" == 2222 ]]
[[ "$INTERNAL_SSH_IDENTITY_FILE" == /root/.ssh/test-key && "$INTERNAL_SSH_SOURCE" == override ]]
INTERNAL_SSH_RESOLVE_VM 155 192.0.2.155 root 22
[[ "$INTERNAL_SSH_HOST" == 192.0.2.155 && "$INTERNAL_SSH_USER" == admin && "$INTERNAL_SSH_PORT" == 2200 ]]

printf '%s\n' 'schema_version=1' '[node:bad]' 'port=65536' > "$WORK_DIR/invalid.conf"
if INTERNAL_SSH_LOAD "$WORK_DIR/invalid.conf"; then
  echo 'invalid port was accepted' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(source|eval)[[:space:]]' "$ROOT_DIR/internal-ssh.sh"; then
  echo 'internal SSH parser must not source or eval configuration' >&2
  exit 1
fi
printf '%s\n' 'internal SSH parser and resolution tests: PASS'
