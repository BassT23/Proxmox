#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The explicit node path must carry a host-only scope locally and remotely.
grep -Fq 'UU_DEFER_NOTIFICATION=true UU_CHECK_SCOPE=host STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" node-host' \
  "$ROOT_DIR/ultimate-updater"
grep -Fq 'INTERNAL_SSH_RESOLVE_NODE "$node" "$host" "$default_port"' "$ROOT_DIR/ultimate-updater"
grep -Fq 'REMOTE_NODE_USER="${INTERNAL_SSH_USER:-root}"' "$ROOT_DIR/ultimate-updater"
grep -Fq '"$user@$host:$remote_config"' "$ROOT_DIR/ultimate-updater"
grep -Fq '"$user@$host" "$command"' "$ROOT_DIR/ultimate-updater"
grep -Fq 'bash -s -- node-host' "$ROOT_DIR/check-updates.sh"
grep -Fq 'bash %q node-host' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_CHECK_SCOPE=host TAG_FILTER_FILE=' "$ROOT_DIR/check-updates.sh"
grep -Fq '"${UU_CHECK_SCOPE:-}" != host && "$WITH_LXC" == true' "$ROOT_DIR/check-updates.sh"
grep -Fq '"${UU_CHECK_SCOPE:-}" != host && "$WITH_VM" == true' "$ROOT_DIR/check-updates.sh"

# Remote check-node must finalize and validate its own status artifact before
# returning it. A missing artifact is a classified failure, not JSON input.
grep -Fq 'UU_REMOTE_DEFER_STATUS_FINISH=true' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_MODEL_PARTIAL=true' "$ROOT_DIR/ultimate-updater"
grep -Fq 'Remote node status was not produced for %s.' "$ROOT_DIR/ultimate-updater"
grep -Fq 'REMOTE_STATUS_MISSING' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_MODEL_IMPORT_FILE "$local_file" 2>/dev/null' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_MODEL_NODE=%q; STATUS_MODEL_FILE=%q; STATUS_MODEL_RECORD_FILE=%q; . %q' "$ROOT_DIR/ultimate-updater"
if grep -Fq 'bash '\''/etc/ultimate-updater/check-updates.sh'\'' node-host >/dev/null 2>&1; cat' "$ROOT_DIR/ultimate-updater"; then
  echo 'remote check-node still blindly cats the status artifact' >&2
  exit 1
fi

echo 'check node host-only scope tests: PASS'
