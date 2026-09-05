#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)

bash -n "$ROOT_DIR/install.sh" "$ROOT_DIR/update.sh" "$ROOT_DIR/tag-filter.sh"

for file in install.sh update.sh tag-filter.sh; do
  grep -Fq -- '--retry 0' "$ROOT_DIR/$file"
  grep -Fq -- '429' "$ROOT_DIR/$file" || [[ "$file" == install.sh || "$file" == update.sh ]]
done

if rg -n 'bash <\(curl|source <\(curl|curl[^\n]*\|[[:space:]]*(bash|sh)|wget[^\n]*\|[[:space:]]*(bash|sh)' \
  "$ROOT_DIR/install.sh" "$ROOT_DIR/update.sh" "$ROOT_DIR/tag-filter.sh"; then
  echo 'unsafe executable download pipeline found' >&2
  exit 1
fi

grep -Fq 'Retry-After' "$ROOT_DIR/install.sh"
grep -Fq 'Retry-After' "$ROOT_DIR/update.sh"
grep -Fq 'Retry-After' "$ROOT_DIR/tag-filter.sh"
grep -Fq 'bash -n' "$ROOT_DIR/install.sh"
grep -Fq 'bash -n' "$ROOT_DIR/update.sh"
grep -Fq 'tar -tzf' "$ROOT_DIR/install.sh"

echo 'HTTP download safety tests: PASS'
