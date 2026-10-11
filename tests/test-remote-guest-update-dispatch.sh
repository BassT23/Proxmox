#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPDATER="$ROOT_DIR/ultimate-updater"

# Guest updates use the same temporary central-script transfer as node updates.
grep -Fq 'remote_update_job()' "$UPDATER"
grep -Fq 'remote_update_job "$target" "$target" "$node" "$host"' "$UPDATER"
grep -Fq 'remote_update_job host "node-$1" "$1" "$2"' "$UPDATER"
grep -Fq 'UU_LOCAL_FILES=%q UU_REMOTE_WORK_DIR=%q' "$UPDATER"
grep -Fq '"$remote_update_dir/update.sh" "$remote_target"' "$UPDATER"
grep -Fq '"$JOB_RUNNER" record-remote "$job_unit" "$target" "$node" "$host" "$port" "$remote_update_dir"' "$UPDATER"
grep -Fq '"$LOCAL_FILES/exit/error.sh"' "$UPDATER"
grep -Fq '$remote_update_dir/exit/$(basename -- "$source")' "$UPDATER"
grep -Fq '"$LOCAL_FILES/target-selection.sh" "$target_selection_file"' "$UPDATER"
grep -Fq '"$LOCAL_FILES/job-pty-bridge.py"' "$UPDATER"
grep -Fq 'UU_TARGET_SELECTION_FILE=%q' "$UPDATER"
grep -Fq 'UU_JOB_INTERACTIVE=true ' "$UPDATER"
grep -Fq '"$CHECK_CLI" status-import "$local_status_file"' "$ROOT_DIR/job-runner.sh"
grep -Fq 'post-update-status.rc' "$ROOT_DIR/update.sh"
grep -Fq "chmod 750 '\$remote_update_dir/job-runner.sh' '\$remote_update_dir/update.sh' '\$remote_update_dir/check-updates.sh'" "$UPDATER"
grep -Fq "'\$remote_update_dir/job-pty-bridge.py'" "$UPDATER"
grep -Fq 'CONFIG_FILE="${UU_UPDATE_CONFIG_FILE:-$LOCAL_FILES/update.conf}"' "$ROOT_DIR/update-extras.sh"

# Build identity is used by the remote update job and must be part of the
# temporary payload; otherwise the staged update.sh calls an undefined helper.
grep -Fq 'local product_metadata_file="$LOCAL_FILES/product-metadata.sh"' "$UPDATER"
grep -Fq '"$LOCAL_FILES/windows-update.sh" "$product_metadata_file" "$package_count_file"' "$UPDATER"
grep -Fq 'local apt_count_file rpm_count_file package_count_file product_metadata_file source' "$ROOT_DIR/update.sh"
grep -Fq '"$product_metadata_file"; do' "$ROOT_DIR/update.sh"
grep -Fq 'Could not stage product metadata for remote update on %s.' "$UPDATER"
grep -Fq 'Could not stage product metadata for remote host $HOST' "$ROOT_DIR/update.sh"

# A remote guest update must not depend on a complete UU installation on the owner node.
if grep -Fq '"/etc/ultimate-updater/job-runner.sh" start "$target"' "$UPDATER"; then
  printf 'legacy remote guest runner path still present\n' >&2
  exit 1
fi

printf 'remote guest update dispatch tests: PASS\n'
