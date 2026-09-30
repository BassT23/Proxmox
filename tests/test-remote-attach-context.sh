#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT_DIR/job-runner.sh"

# Remote attach must use the running job's transferred runtime, never a
# potentially different installed bridge on the owner node.
grep -Fq 'UU_LOCAL_FILES=%q UU_REMOTE_WORK_DIR=%q UU_PTY_BRIDGE=%q' "$RUNNER"
grep -Fq '"$workspace/job-pty-bridge.py" "$runner" "$unit"' "$RUNNER"
grep -Fq '"$workspace" =~ ^/tmp/ultimate-updater-update-node-' "$RUNNER"
grep -Fq 'Remote job workspace is invalid' "$RUNNER"

printf 'remote attach runtime context tests: PASS\n'
