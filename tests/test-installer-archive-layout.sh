#!/bin/bash
# shellcheck disable=SC2016,SC2034 # Literal grep assertions and sourced fixture globals are intentional.
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)

grep -Fq "listing=\$(tar -tzf \"\$temporary\")" "$ROOT_DIR/install.sh"
grep -Fq 'SET_TEMP_FILES()' "$ROOT_DIR/install.sh"
grep -Fq 'SET_TEMP_FILES || return 1' "$ROOT_DIR/install.sh"
grep -Fq 'SET_TEMP_FILES || exit 1' "$ROOT_DIR/install.sh"
grep -Fq 'WELCOME_SCREEN_INSTALL "$TEMP_FILES/welcome-screen.sh"' "$ROOT_DIR/install.sh"
grep -Fq 'local welcome_source="${1:-$TEMP_FOLDER/welcome-screen.sh}"' "$ROOT_DIR/install.sh"
grep -Fq 'Welcome-Screen asset is missing' "$ROOT_DIR/install.sh"
grep -Fq 'cp "$welcome_source" /etc/update-motd.d/01-welcome-screen' "$ROOT_DIR/install.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# Exercise the same resolver with a GitHub-release style nested archive root.
mkdir -p "$work_dir/ultimate-updater-5.1.1"
touch "$work_dir/ultimate-updater-5.1.1/update.sh"
TEMP_FOLDER="$work_dir"
TEMP_FILES=''
eval "$(sed -n '/^SET_TEMP_FILES()/,/^}/p' "$ROOT_DIR/install.sh")"
SET_TEMP_FILES
[[ "$TEMP_FILES" == "$work_dir/ultimate-updater-5.1.1" ]]

# A root-level archive remains supported for existing fixtures.
rm -rf "$work_dir/ultimate-updater-5.1.1"
touch "$work_dir/update.sh"
TEMP_FILES=''
SET_TEMP_FILES
[[ "$TEMP_FILES" == "$work_dir" ]]

# The post-install Welcome-Screen step must use the resolved payload root for
# nested archives while the standalone welcome command keeps its temp-file
# fallback.
grep -Fq 'WELCOME_SCREEN_INSTALL "$TEMP_FOLDER/welcome-screen.sh"' "$ROOT_DIR/install.sh"

echo 'installer archive layout tests: PASS'
