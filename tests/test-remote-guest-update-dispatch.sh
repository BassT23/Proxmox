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
grep -Fq '"$JOB_RUNNER" record-remote "$job_unit" "$target" "$node" "$host" "$port"' "$UPDATER"
grep -Fq '"$LOCAL_FILES/exit/error.sh"' "$UPDATER"
grep -Fq '$remote_update_dir/exit/$(basename -- "$source")' "$UPDATER"

# A remote guest update must not depend on a complete UU installation on the owner node.
if grep -Fq '"/etc/ultimate-updater/job-runner.sh" start "$target"' "$UPDATER"; then
  printf 'legacy remote guest runner path still present\n' >&2
  exit 1
fi

printf 'remote guest update dispatch tests: PASS\n'
