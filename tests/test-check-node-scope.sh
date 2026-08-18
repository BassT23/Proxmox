#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The explicit node path must carry a host-only scope locally and remotely.
grep -Fq 'UU_DEFER_NOTIFICATION=true UU_CHECK_SCOPE=host STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" node-host' \
  "$ROOT_DIR/ultimate-updater"
grep -Fq 'bash -s -- node-host' "$ROOT_DIR/check-updates.sh"
grep -Fq "bash '/etc/ultimate-updater/check-updates.sh' node-host" "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_CHECK_SCOPE=host TAG_FILTER_FILE=' "$ROOT_DIR/check-updates.sh"
grep -Fq '"${UU_CHECK_SCOPE:-}" != host && "$WITH_LXC" == true' "$ROOT_DIR/check-updates.sh"
grep -Fq '"${UU_CHECK_SCOPE:-}" != host && "$WITH_VM" == true' "$ROOT_DIR/check-updates.sh"

echo 'check node host-only scope tests: PASS'
