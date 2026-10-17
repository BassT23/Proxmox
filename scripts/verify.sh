#!/usr/bin/env bash
# Repository-owned source-only regression gate. Never install or update a host.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export PYTHONDONTWRITEBYTECODE=1

# Test only product source and fixtures; this is not an artifact verifier.
python3 - web-ui/server.py <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
compile(path.read_bytes(), str(path), "exec")
PY

for source in install.sh update.sh status-model.sh job-runner.sh check-updates.sh; do
  bash -n "$source"
done

py_count=0
for test in tests/test-*.py; do
  if [[ ! -f "$test" ]]; then
    echo "Expected Python source tests missing: $test" >&2
    exit 1
  fi
  python3 "$test"
  py_count=$((py_count + 1))
done

# Explicit source-only safety allowlist. Never execute a real-cluster test.
shell_tests=(
  tests/test-source-verify-entrypoint.sh
  tests/test-installer-archive-layout.sh
  tests/test-installer-bootstrap.sh
  tests/test-installer-header-exit.sh
  tests/test-installer-terminal-ux.sh
  tests/test-installer-scheduled-cron.sh
  tests/test-http-download-safety.sh
  tests/test-branch-selection.sh
  tests/test-config-merge.sh
  tests/test-initial-inventory-readonly.sh
  tests/test-initial-inventory-guest-preflight.sh
  tests/test-product-version-identity.sh
  tests/test-mail-renderer.sh
  tests/test-check-only-finalization.sh
  tests/test-post-update-refresh.sh
  tests/test-update-summary-pending-before.sh
  tests/test-status-writer-concurrency.sh
)
shell_count=0
for test in "${shell_tests[@]}"; do
  if [[ ! -f "$test" ]]; then
    echo "Required source-only fixture missing: $test" >&2
    exit 1
  fi
  bash "$test"
  shell_count=$((shell_count + 1))
done
printf 'Ultimate Updater source-only verification PASS: %s Python tests and %s shell fixtures.\n' "$py_count" "$shell_count"
