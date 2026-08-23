#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# A remote legacy VM check must receive only the selected profile in its
# run-scoped VMs directory.  It must not rely on a persistent installation on
# the owner node or silently fall back to QGA when transfer fails.
grep -Fq 'legacy_profile="$LOCAL_FILES/VMs/$target"' "$ROOT_DIR/ultimate-updater"
grep -Fq '$remote_check_dir/VMs/$target' "$ROOT_DIR/ultimate-updater"
grep -Fq 'mkdir -p -- '\''$remote_check_dir'\'' '\''$remote_check_dir/VMs'\''' "$ROOT_DIR/ultimate-updater"
grep -Fq 'Could not transfer legacy SSH profile for target %s to node %s.' "$ROOT_DIR/ultimate-updater"

# The remote update dispatch must use the same single-profile transfer and
# clean up its temporary workspace on failure.
grep -Fq 'local legacy_profile="$LOCAL_FILES/VMs/$target"' "$ROOT_DIR/ultimate-updater"
grep -Fq '$remote_update_dir/VMs/$target' "$ROOT_DIR/ultimate-updater"
grep -Fq 'Could not transfer legacy SSH profile for target %s to %s.' "$ROOT_DIR/ultimate-updater"

# No remote code path may copy the complete legacy profile directory.
if grep -Eq 'scp[^\n]*VMs/\*|scp[^\n]*VMs/"?\$' "$ROOT_DIR/ultimate-updater"; then
  echo 'remote legacy transfer is broader than the selected VM profile' >&2
  exit 1
fi

echo 'remote legacy SSH profile transfer tests: PASS'
