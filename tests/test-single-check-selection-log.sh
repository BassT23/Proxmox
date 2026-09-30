#!/usr/bin/env bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK_SOURCE="$ROOT_DIR/check-updates.sh"
CLI_SOURCE="$ROOT_DIR/ultimate-updater"

grep -Fq '"${UU_SINGLE_TARGET_CHECK:-false}" != true' "$CHECK_SOURCE"
grep -Fq 'UU_SINGLE_TARGET_CHECK=true UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" chost' "$CLI_SOURCE"
grep -Fq 'UU_SINGLE_TARGET_CHECK=true UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" ccontainer' "$CLI_SOURCE"
grep -Fq 'UU_SINGLE_TARGET_CHECK=true UU_DEFER_NOTIFICATION=true UU_EXPLICIT_TARGET_CHECK=true STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" cvm' "$CLI_SOURCE"
grep -Fq 'UU_SINGLE_TARGET_CHECK=true' "$CLI_SOURCE"

echo 'single-target selection log tests: PASS'
