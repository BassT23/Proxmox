#!/bin/bash
# shellcheck disable=SC1091,SC2034,SC2251
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

sed -n '198,202p' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/trace.sh"
cat >> "$WORK_DIR/trace.sh" <<'EOF'
STATUS_MODEL_DIAGNOSTIC() { printf '%s\n' "$*" >> "$TRACE_FILE"; }
EOF
source "$WORK_DIR/trace.sh"

TRACE_FILE="$WORK_DIR/trace.log"
UU_REMOTE_TRACE=false
REMOTE_TRACE 'host=host:node2 step=should_not_appear'
[[ ! -s "$TRACE_FILE" ]]

UU_REMOTE_TRACE=true
REMOTE_TRACE 'host=host:node2 step=remote_launch rc=0'
grep -Fq 'REMOTE_TRACE host=host:node2 step=remote_launch rc=0' "$TRACE_FILE"
if grep -Eq '([Pp]assword|PRIVATE KEY|identity_file=|192\.168\.)' "$TRACE_FILE"; then
  exit 1
fi

for step in check_host_enter helper_prepare helper_copy remote_launch completion_fetch remote_rc status_fetch diagnostics_fetch result_import result_emitted check_host_exit; do
  grep -Fq "step=$step" "$ROOT_DIR/check-updates.sh"
done

echo 'remote check trace tests: PASS'
