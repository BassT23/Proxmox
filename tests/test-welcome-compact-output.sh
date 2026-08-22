#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^COMPACT_WELCOME_OUTPUT \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/welcome-screen.sh" > "$WORK_DIR/formatter.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/formatter.sh"

cat > "$WORK_DIR/check-output" <<'EOF'
Available Updates:
S = Security / N = Normal
Host : node1
Normal updates: 3
Security updates: 4
LXC 105 : pdm
Normal updates: 20
Security updates: 23
VM 101 : omv
Normal updates: 51
Security updates: 28
LXC 200 : healthy
Normal updates: 0
Security updates: 0
VM 300 : partial
Normal updates: 4
Security updates: Unknown
LXC 400 : unknown
Normal updates: Unknown
Security updates: 1
LXC 211 : iobroker
Check failed: apt-get update failed
EOF

actual=$(COMPACT_WELCOME_OUTPUT "$WORK_DIR/check-output")
expected=$(cat <<'EOF'
Available Updates:
S = Security / N = Normal
Host : node1
S: 4 / N: 3
LXC 105 : pdm
S: 23 / N: 20
VM 101 : omv
S: 28 / N: 51
LXC 200 : healthy
S: 0 / N: 0
VM 300 : partial
S: Unknown / N: 4
LXC 400 : unknown
S: 1 / N: Unknown
LXC 211 : iobroker
Check failed: apt-get update failed
EOF
)

[[ "$actual" == "$expected" ]]
if grep -Fq 'Normal updates:' <<<"$actual" ||
   grep -Fq 'Security updates:' <<<"$actual"; then
  echo 'verbose update labels remain in compact welcome output' >&2
  exit 1
fi
printf '%s\n' 'welcome compact output tests: PASS'
