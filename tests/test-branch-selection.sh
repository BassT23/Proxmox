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
grep -Fq 'tarball/' "$ROOT_DIR/install.sh"
grep -Fq 'INSTALLED_BRANCH=' "$ROOT_DIR/update.sh"
grep -Fq 'BRANCH=master' "$ROOT_DIR/update.sh"
grep -Fq 'The bare -up is always the' "$ROOT_DIR/update.sh"
grep -Fq 'Interactive confirmation required for a downgrade' "$ROOT_DIR/update.sh"
grep -Fq 'Continue with downgrade? [y/N]' "$ROOT_DIR/update.sh"
grep -Fq 'Update/install the stable master branch' "$ROOT_DIR/update.sh"
grep -Fq 'PRINT_BRANCH_PROMPT ()' "$ROOT_DIR/update.sh"
grep -Fq 'beta) branch_color="$OR"' "$ROOT_DIR/update.sh"
grep -Fq 'develop) branch_color="$RD"' "$ROOT_DIR/update.sh"
grep -Fq "printf 'Update to %b%s%b branch?\\n'" "$ROOT_DIR/update.sh"
grep -Fq "BRANCH=\"\${UU_TARGET_BRANCH:-" "$ROOT_DIR/install.sh"
if grep -Fq 'beta branch is no longer active' "$ROOT_DIR/update.sh" "$ROOT_DIR/welcome-screen.sh"; then
  exit 1
fi
if grep -Fq 'beta-outdated' "$ROOT_DIR/README.md" "$ROOT_DIR/RELEASE_NOTES_5.1_BETA.md" "$ROOT_DIR/UPGRADE_NOTES_5.1.md"; then
  exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
printf 'USED_BRANCH="develop"\n' > "$work_dir/update.conf"
printf 'NEW_OPTION=true\n' > "$work_dir/update.conf.dist"
# shellcheck disable=SC1091
source "$ROOT_DIR/config-merge.sh"
MERGE_UPDATE_CONFIG "$work_dir/update.conf" "$work_dir/update.conf.dist" beta
grep -Fqx 'USED_BRANCH="beta"    # could be "master/beta/develop"' "$work_dir/update.conf"

grep -Fq 'https://raw.githubusercontent.com/BassT23/Proxmox/' "$ROOT_DIR/update.sh"

echo 'branch selection tests: PASS'
