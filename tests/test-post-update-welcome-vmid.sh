#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

python3 - "$ROOT_DIR/update.sh" "$ROOT_DIR/check-updates.sh" <<'PY'
import pathlib
import sys

update = pathlib.Path(sys.argv[1]).read_text()
check = pathlib.Path(sys.argv[2]).read_text()

welcome = update.split('UPDATE_CHECK () {', 1)[1].split('\n}\n', 1)[0]
assert ' -u ccontainer "$CONTAINER"' in welcome
assert 'status_target="$CONTAINER"' in welcome
assert 'STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u ccontainer | tee -a "$LOCAL_FILES/check-output"' not in welcome
assert ' -u cvm \\"$VM\\"' in welcome
assert 'status_target="$VM"' in welcome

lifecycle = check.split('CHECK_VM_LIFECYCLE () {', 1)[1].split('\n}\n', 1)[0]
assert 'missing or invalid VMID' in lifecycle
assert 'qm status "$VM"' in lifecycle
assert '^[0-9]+$' in lifecycle
PY

if grep -nE 'check-updates\.sh[^\n]*-u cvm"' "$ROOT_DIR/update.sh"; then
  echo 'bare cvm welcome-status invocation remains' >&2
  exit 1
fi

echo 'post-update welcome VMID propagation tests: PASS'
