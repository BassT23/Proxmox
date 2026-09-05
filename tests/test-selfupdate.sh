#!/bin/bash
# shellcheck disable=SC2016 # grep assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Load only CHECK_DIFF from the installer; sourcing install.sh itself would run
# its normal installation entry point.
awk '/^CHECK_DIFF \(\) \{/{copy=1} /^WELCOME_SCREEN \(\) \{/{exit} copy' \
  "$ROOT_DIR/install.sh" > "$WORK_DIR/check-diff.sh"

mkdir -p "$WORK_DIR/local" "$WORK_DIR/source"
printf 'repository version\n' > "$WORK_DIR/source/managed-file"
printf 'local edit\n' > "$WORK_DIR/local/managed-file"

LOCAL_FILES="$WORK_DIR/local" TEMP_FILES="$WORK_DIR/source" FILE=managed-file \
  UU_NONINTERACTIVE=true bash -c 'source "$1"; CHECK_DIFF' _ "$WORK_DIR/check-diff.sh" > "$WORK_DIR/output"

grep -Fqx 'repository version' "$WORK_DIR/local/managed-file"
grep -Fqx 'local edit' "$WORK_DIR/local/managed-file.bak"
if grep -Fq 'What would you like' "$WORK_DIR/output"; then
  exit 1
fi
if grep -Fq '.bak' "$WORK_DIR/output"; then
  exit 1
fi

printf 'repository version 2\n' > "$WORK_DIR/source/managed-file"
printf 'existing backup\n' > "$WORK_DIR/local/managed-file.bak"
# shellcheck disable=SC2016
LOCAL_FILES="$WORK_DIR/local" TEMP_FILES="$WORK_DIR/source" FILE=managed-file \
  env -u UU_NONINTERACTIVE bash -c 'source "$1"; CHECK_DIFF' _ "$WORK_DIR/check-diff.sh" \
  </dev/null > "$WORK_DIR/no-tty-output"
grep -Fqx 'repository version 2' "$WORK_DIR/local/managed-file"
grep -Fqx 'existing backup' "$WORK_DIR/local/managed-file.bak"
if grep -Fq 'What would you like' "$WORK_DIR/no-tty-output"; then
  exit 1
fi
if grep -Fq '.bak' "$WORK_DIR/no-tty-output"; then
  exit 1
fi

grep -Fq 'target_commit=$(FETCH_REMOTE_COMMIT "$BRANCH" || true)' "$ROOT_DIR/update.sh"
grep -Fq 'The Ultimate Updater is UpToDate' "$ROOT_DIR/update.sh"
grep -Fq 'for attempt in 1 2 3' "$ROOT_DIR/tag-filter.sh"

echo 'self-update unattended tests: PASS'
