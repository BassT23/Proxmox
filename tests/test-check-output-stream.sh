#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK_SCRIPT="$ROOT_DIR/check-updates.sh"

# APT checks refresh package lists before consuming structured metadata and do
# not parse localized package-manager simulation output.
grep -Fq 'REFRESH_APT_PACKAGE_LISTS' "$CHECK_SCRIPT"
grep -Fq 'apt-get update -y' "$CHECK_SCRIPT"
if grep -Fq 'apt-get -s' "$CHECK_SCRIPT"; then
  exit 1
fi
grep -Fq 'READ_APT_UPDATE_COUNTS' "$CHECK_SCRIPT"
grep -Fq 'if ! RUN_PCT_COMMAND "$CONTAINER" ash -c "apk update"; then' "$CHECK_SCRIPT"

echo 'check output streaming tests: PASS'
