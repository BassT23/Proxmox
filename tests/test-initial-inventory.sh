#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
INSTALLER="$ROOT_DIR/install.sh"

grep -Fq 'INITIAL_INVENTORY_STATE_FILE="/var/lib/ultimate-updater/initial-inventory.state"' "$INSTALLER"
grep -Fq 'START_INITIAL_INVENTORY ()' "$INSTALLER"
grep -Fq "start-check all-systems \"\$cli\" all" "$INSTALLER"
grep -Fq 'UU_JOB_SOURCE=initial-inventory timeout 15' "$INSTALLER"
grep -Fq 'Initial system inventory started.' "$INSTALLER"
grep -Fq 'state=start_failed' "$INSTALLER"
grep -Fq "printf 'job=%s\\n'" "$INSTALLER"
grep -Fq "printf 'source=%s\\n'" "$ROOT_DIR/job-runner.sh"
grep -Fq "job.source==='initial-inventory'?'INITIAL INVENTORY'" "$ROOT_DIR/web-ui/server.py"
grep -Fq 'Target preview unavailable until the initial inventory has completed.' "$ROOT_DIR/web-ui/server.py"
if grep -Fq "job.source==='initial-inventory'?'INVENTORY SCAN'" "$ROOT_DIR/web-ui/server.py"; then
  exit 1
fi

fresh_setup=$(awk '/^[[:space:]]*SETUP_WEB_SERVICE start$/{print NR; exit}' "$INSTALLER")
fresh_inventory=$(awk '/^[[:space:]]*START_INITIAL_INVENTORY$/{print NR; exit}' "$INSTALLER")
upgrade_setup=$(awk '/^[[:space:]]*SETUP_WEB_SERVICE restart$/{print NR; exit}' "$INSTALLER")
upgrade_inventory=$(awk '/^[[:space:]]*SETUP_WEB_SERVICE restart$/{seen=1} seen && /^[[:space:]]*START_INITIAL_INVENTORY$/{print NR; exit}' "$INSTALLER")
[[ -n "$fresh_setup" && -n "$fresh_inventory" && "$fresh_inventory" -gt "$fresh_setup" ]]
[[ -n "$upgrade_setup" && -n "$upgrade_inventory" && "$upgrade_inventory" -gt "$upgrade_setup" ]]

# The installer trigger must use the check job path, never an update command.
if sed -n '/START_INITIAL_INVENTORY ()/,/^}/p' "$INSTALLER" | grep -Eq 'update -check|update-all|start-global|start_job'; then
  exit 1
fi

echo 'initial inventory bootstrap tests: PASS'
