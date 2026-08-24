#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
INSTALLER="$ROOT_DIR/install.sh"

helper_line=$(awk '/^UPDATE \(\)/ { in_update=1 } in_update && /CONFIG_MERGE_SOURCE=/ { print NR; exit }' "$INSTALLER")
copy_line=$(awk '/^UPDATE \(\)/ { in_update=1 } in_update && /^    # Copy files$/ { print NR; exit }' "$INSTALLER")
source_line=$(awk '/^UPDATE \(\)/ { in_update=1 } in_update && /source "\$CONFIG_MERGE_SOURCE"/ { print NR; exit }' "$INSTALLER")
[[ -n "$helper_line" && -n "$copy_line" && -n "$source_line" ]]
(( helper_line < copy_line ))
(( source_line < copy_line ))
if grep -Fq "source \"\$LOCAL_FILES/config-merge.sh\"" "$INSTALLER"; then
  exit 1
fi
grep -Fq 'Interactive confirmation required for upgrade from version 5.0 or earlier' "$INSTALLER"
grep -Fq 'UPGRADE_RESTART_REQUIRED=true' "$INSTALLER"
grep -Fq 'A restart of this Proxmox host is required' "$INSTALLER"
grep -Fq 'The host remains usable' "$INSTALLER"
grep -Fq 'Web UI ready on port' "$INSTALLER"
grep -Fq 'Updating Ultimate Updater...' "$INSTALLER"
grep -Fq "Installed: \$BRANCH" "$INSTALLER"
grep -Fq "rm -rf \"\$TEMP_FILES\"/tests" "$INSTALLER"
grep -Fq "remove_non_runtime_payload \"\$TEMP_FILES\"" "$INSTALLER"
grep -Fq "remove_non_runtime_payload \"\$LOCAL_FILES\"" "$INSTALLER"
grep -Fq 'docs|docs/*|RELEASE_NOTES_5.1_BETA.md|UPGRADE_NOTES_5.1.md' "$INSTALLER"
for repository_file in docs RELEASE_NOTES_5.1_BETA.md UPGRADE_NOTES_5.1.md; do
  [[ -e "$ROOT_DIR/$repository_file" ]]
done
if grep -Fq 'For infos and warnings please check the readme' "$INSTALLER"; then
  exit 1
fi
if grep -Fq 'old file saved as' "$INSTALLER"; then
  exit 1
fi
grep -Fq 'UU_UPGRADE_INTERACTIVE=true' "$ROOT_DIR/update.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
printf 'USED_BRANCH="master"\nOLD_VALUE="kept"\n' > "$work_dir/update.conf"
printf 'USED_BRANCH="develop"\nNEW_VALUE="default"\n' > "$work_dir/update.conf.dist"
# shellcheck disable=SC1091
source "$ROOT_DIR/config-merge.sh"
MERGE_UPDATE_CONFIG "$work_dir/update.conf" "$work_dir/update.conf.dist" beta
grep -Fqx 'USED_BRANCH="beta"    # could be "master/beta/develop"' "$work_dir/update.conf"
grep -Fqx 'OLD_VALUE="kept"' "$work_dir/update.conf"
grep -Fqx 'NEW_VALUE="default"' "$work_dir/update.conf"

printf 'not valid shell (' > "$work_dir/invalid-config-merge.sh"
if bash -n "$work_dir/invalid-config-merge.sh" 2>/dev/null; then
  exit 1
fi
[[ ! -e "$work_dir/missing-target.conf" ]]

printf 'installer bootstrap migration tests: PASS\n'
