#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK_SCRIPT="$ROOT_DIR/check-updates.sh"

# APT checks consume cached structured metadata and must not refresh package
# lists or parse package-manager output.
if grep -Eq '(^|[[:space:]])apt-get update([[:space:]";]|$)' "$CHECK_SCRIPT"; then
  exit 1
fi
grep -Fq 'READ_APT_UPDATE_COUNTS' "$CHECK_SCRIPT"
grep -Fq 'if ! RUN_PCT_COMMAND "$CONTAINER" ash -c "apk update"; then' "$CHECK_SCRIPT"

echo 'check output streaming tests: PASS'
