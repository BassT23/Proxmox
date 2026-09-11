#!/bin/bash
# shellcheck disable=SC2016 # Assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

grep -Fq 'EFFECTIVE_HEADLESS()' "$ROOT_DIR/update.sh"
grep -Fq 'IN_HEADLESS_MODE=$(awk' "$ROOT_DIR/update.sh"
grep -Fq 'APT_COMMAND()' "$ROOT_DIR/update.sh"
grep -Fq 'configured_headless()' "$ROOT_DIR/ultimate-updater"
grep -Fq 'Environment=UU_JOB_INTERACTIVE=true' "$ROOT_DIR/web-ui/server.py"
grep -Fq 'IN_HEADLESS_MODE=$(awk' "$ROOT_DIR/update-extras.sh"
grep -Fq 'UU_EFFECTIVE_HEADLESS' "$ROOT_DIR/external-helper.sh"
grep -Fq '__UU_EFFECTIVE_HEADLESS__' "$ROOT_DIR/external-apt.sh"
grep -Fq -- '--force-confdef' "$ROOT_DIR/update.sh"
grep -Fq -- '--force-confold' "$ROOT_DIR/update.sh"

echo "headless policy tests: PASS"
