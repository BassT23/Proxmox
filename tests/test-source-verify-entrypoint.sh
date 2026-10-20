#!/usr/bin/env bash
# Contract test for the adapted X1/X1pheR Issue #375 / PR #376 verifier.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ENTRYPOINT="$ROOT_DIR/scripts/verify.sh"

[[ -f "$ENTRYPOINT" ]]
bash -n "$ENTRYPOINT"
grep -Fq 'set -euo pipefail' "$ENTRYPOINT"
grep -Fq 'PYTHONDONTWRITEBYTECODE=1' "$ENTRYPOINT"
grep -Fq 'tests/test-*.py' "$ENTRYPOINT"
grep -Fq 'tests/test-source-verify-entrypoint.sh' "$ENTRYPOINT"
grep -Fq 'Issue #375 / PR #376' "$ENTRYPOINT"
grep -Fq 'X1/X1pheR' "$ENTRYPOINT"

for file in \
  tests/test-native-staged-source.sh \
  tests/test-installer-archive-layout.sh \
  tests/test-installer-bootstrap.sh \
  tests/test-http-download-safety.sh \
  tests/test-initial-inventory-readonly.sh \
  tests/test-config-merge.sh \
  tests/test-status-writer-concurrency.sh; do
  grep -Fq "$file" "$ENTRYPOINT"
done
grep -Fq 'tests/test-scheduled-success-heartbeat.sh' "$ENTRYPOINT"

# The verifier itself must not dispatch host, guest, package, or network tools.
# Child fixtures may define local command mocks; that is why the check targets
# the repository-owned entrypoint rather than scanning all test source text.
if grep -Eq '^[[:space:]]*[^#]*(systemctl|systemd-run|pvesh|qm|pct|apt-get|apt-cache|dnf|yum|pacman|apk|pkg|ssh|scp|curl|wget|nc|socat|reboot|shutdown)([[:space:]]|$)' "$ENTRYPOINT"; then
  echo 'source-only verifier contains a forbidden host, guest, package, or network command' >&2
  exit 1
fi

# Required fixtures must fail closed; no optional existence guard may silently
# omit a selected test.
if grep -Eq '\[\[ -f "[^"]+" \]\] (&&|\|\|)' "$ENTRYPOINT" \
  && ! grep -Fq 'Required source-only fixture missing' "$ENTRYPOINT"; then
  echo 'required source-only fixtures are not fail-closed' >&2
  exit 1
fi

echo 'product-owned source verifier entrypoint contract: PASS'
