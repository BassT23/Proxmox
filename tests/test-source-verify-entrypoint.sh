#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
entry="$root/scripts/verify.sh"
test -f "$entry"
bash -n "$entry"
grep -Fq 'set -euo pipefail' "$entry"
grep -Fq 'PYTHONDONTWRITEBYTECODE=1' "$entry"
grep -Fq 'tests/test-*.py' "$entry"
grep -Fq 'tests/test-source-verify-entrypoint.sh' "$entry"
for file in \
  tests/test-installer-archive-layout.sh \
  tests/test-installer-bootstrap.sh \
  tests/test-http-download-safety.sh \
  tests/test-initial-inventory-readonly.sh \
  tests/test-config-merge.sh; do
    grep -Fq "$file" "$entry"
done
if grep -Eq '\b(systemctl|qm|pct|apt-get|sudo|curl|wget)\b' "$entry"; then
  echo 'source-only verification entrypoint must not execute live host tools' >&2
  exit 1
fi
grep -Fq '[[ -f "$test" ]] ||' "$entry" && {
  echo 'required source verification fixtures must not be silently skipped' >&2
  exit 1
}
echo 'product-owned source verifier entrypoint contract: PASS'
