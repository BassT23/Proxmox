#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK_SCRIPT="$ROOT_DIR/check-updates.sh"

# Package-manager refresh diagnostics must remain attached to the server-side
# job output.  The command's own exit status must still drive the check result.
grep -Fq '  apt-get update' "$CHECK_SCRIPT"
grep -Fq 'if ! RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get update"; then' "$CHECK_SCRIPT"
grep -Fq 'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apt-get update"' "$CHECK_SCRIPT"
grep -Fq 'if ! RUN_PCT_COMMAND "$CONTAINER" ash -c "apk update"; then' "$CHECK_SCRIPT"
if grep -Fq 'RUN_PCT_COMMAND "$CONTAINER" bash -c "apt-get update" >/dev/null 2>&1' "$CHECK_SCRIPT"; then
  exit 1
fi
if grep -Fq 'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "apt-get update" >/dev/null 2>&1' "$CHECK_SCRIPT"; then
  exit 1
fi

echo 'check output streaming tests: PASS'
