#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)

grep -Fq 'master|beta|develop)' "$ROOT_DIR/update.sh"
grep -Fq 'Use beta branch (pre-release)' "$ROOT_DIR/update.sh"
grep -Fq 'beta) candidates=(master beta)' "$ROOT_DIR/update.sh"
grep -Fq 'beta) candidates=(master beta)' "$ROOT_DIR/welcome-screen.sh"
grep -Fq 'FETCH_REMOTE_VERSION beta update.sh' "$ROOT_DIR/tag-filter.sh"
grep -Fq 'BETA_VERSION=' "$ROOT_DIR/tag-filter.sh"
grep -Fq 'master|beta|develop)' "$ROOT_DIR/install.sh"
grep -Fq 'tarball/$BRANCH' "$ROOT_DIR/install.sh"
! grep -Fq 'beta branch is no longer active' "$ROOT_DIR/update.sh" "$ROOT_DIR/welcome-screen.sh"
! grep -Fq 'beta-outdated' "$ROOT_DIR/README.md" "$ROOT_DIR/RELEASE_NOTES_5.1_BETA.md" "$ROOT_DIR/UPGRADE_NOTES_5.1.md"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
printf 'USED_BRANCH="develop"\n' > "$work_dir/update.conf"
printf 'NEW_OPTION=true\n' > "$work_dir/update.conf.dist"
# shellcheck disable=SC1091
source "$ROOT_DIR/config-merge.sh"
MERGE_UPDATE_CONFIG "$work_dir/update.conf" "$work_dir/update.conf.dist" beta
grep -Fqx 'USED_BRANCH="beta"    # could be "master/beta/develop"' "$work_dir/update.conf"

for branch in master beta develop; do
  grep -Fq "https://raw.githubusercontent.com/BassT23/Proxmox/\$BRANCH" "$ROOT_DIR/update.sh"
done

echo 'branch selection tests: PASS'
