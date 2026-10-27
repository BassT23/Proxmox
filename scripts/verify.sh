#!/usr/bin/env bash
# Source-only verification adapted from X1/X1pheR's Issue #375 / PR #376.
# This entrypoint is intentionally specific to Ultimate Updater's test layout.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

export PYTHONDONTWRITEBYTECODE=1
export UU_SOURCE_VERIFY=1

python3 - web-ui/server.py <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
compile(path.read_bytes(), str(path), "exec")
PY

for source in install.sh update.sh status-model.sh job-runner.sh check-updates.sh; do
  [[ -f "$source" ]] || { printf 'Required shell entrypoint missing: %s\n' "$source" >&2; exit 1; }
  bash -n "$source"
done

python_count=0
for test in tests/test-*.py; do
  [[ -f "$test" ]] || { printf 'Required Python test missing: %s\n' "$test" >&2; exit 1; }
  python3 "$test"
  python_count=$((python_count + 1))
done

# Explicit source-only shell allowlist. Live-cluster, deployment, and
# destructive integration fixtures are deliberately not selected here.
shell_tests=(
  tests/test-source-verify-entrypoint.sh
  tests/test-native-staged-source.sh
  tests/test-installer-archive-layout.sh
  tests/test-installer-bootstrap.sh
  tests/test-installer-header-exit.sh
  tests/test-installer-terminal-ux.sh
  tests/test-installer-scheduled-cron.sh
  tests/test-http-download-safety.sh
  tests/test-external-release-pin.sh
  tests/test-branch-selection.sh
  tests/test-config-merge.sh
  tests/test-initial-inventory-readonly.sh
  tests/test-initial-inventory-guest-preflight.sh
  tests/test-product-version-identity.sh
  tests/test-mail-renderer.sh
  tests/test-apprise-notifications.sh
  tests/test-scheduled-success-heartbeat.sh
  tests/test-check-only-finalization.sh
  tests/test-post-update-refresh.sh
  tests/test-apt-check-refresh.sh
  tests/test-update-apt-baseline-refresh.sh
  tests/test-remote-positive-mutation.sh
  tests/test-remote-target-identity-handoff.sh
  tests/test-update-noop-capability.sh
  tests/test-node-update-scope.sh
  tests/test-update-summary-pending-before.sh
  tests/test-status-writer-concurrency.sh
)

shell_count=0
for test in "${shell_tests[@]}"; do
  [[ -f "$test" ]] || { printf 'Required source-only fixture missing: %s\n' "$test" >&2; exit 1; }
  bash "$test"
  shell_count=$((shell_count + 1))
done

printf 'Ultimate Updater source-only verification PASS: %s Python tests and %s shell fixtures.\n' \
  "$python_count" "$shell_count"
