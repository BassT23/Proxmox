#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE="$ROOT_DIR/ultimate-updater"

# Keep the printf argument contract explicit: the first post-command path is
# the records file, followed by the run-scoped target-selection file.
line=$(awk '/^    "\$remote_runtime" "\$node" "\$remote_status_model"/ { print; exit }' "$SOURCE")
next_line=$(awk '
  /^    "\$remote_runtime" "\$node" "\$remote_status_model"/ { getline; print; exit }
' "$SOURCE")
[[ "$line" == *'"$remote_status_file.records"'* ]]
[[ "$line" != *'"$remote_check_dir/target-selection.json"'* ]]
[[ "$next_line" == *'"$remote_check_dir/target-selection.json"'* ]]

grep -Fq 'STATUS_MODEL_FILE=%q STATUS_MODEL_RECORD_FILE=%q UU_TARGET_SELECTION_FILE=%q' "$SOURCE"
grep -Fq 'STATUS_MODEL_RECORD_FILE=%q; . %q; STATUS_MODEL_FINISH' "$SOURCE"
grep -Fq 'if [[ ! -s %q ]]; then' "$SOURCE"

echo 'remote node status hand-back argument mapping tests: PASS'
