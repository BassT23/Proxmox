#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Exercise the production identity predicate directly, without contacting
# GitHub or running an installer. The UPDATE() gate uses this exact function
# before deciding whether the downloaded installer is required.
awk '/^SAME_INSTALLED_TARGET_IDENTITY\(\)/{capture=1} capture {if (/^PRINT_BRANCH_PROMPT \(\)/) exit; print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-gate.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/update-gate.sh"

assert_installer_required() {
  local name=$1 expected=$2
  shift 2
  set +e
  ( "$@" )
  local rc=$?
  set -e
  if [[ "$expected" == installer && "$rc" -eq 0 ]]; then
    echo "FAIL: $name was classified up to date" >&2
    exit 1
  fi
  if [[ "$expected" == uptodate && "$rc" -ne 0 ]]; then
    echo "FAIL: $name was classified as requiring installer" >&2
    exit 1
  fi
}

set_identity() {
  INSTALLED_VERSION=5.1.3
  target_version=5.1.3
  INSTALLED_COMMIT=8915edfe6652b504fd8762ebe743fc7883a621b1
  installed_commit=$INSTALLED_COMMIT
  target_commit=$INSTALLED_COMMIT
  INSTALLED_BETA=7
  target_beta=7
  INSTALLED_BRANCH=$1
  BRANCH=$2
}

set_identity develop beta
assert_installer_required 'develop -> beta at same commit' installer SAME_INSTALLED_TARGET_IDENTITY

set_identity beta beta
assert_installer_required 'beta -> beta at same commit' uptodate SAME_INSTALLED_TARGET_IDENTITY

set_identity develop master
assert_installer_required 'develop -> master at same commit' installer SAME_INSTALLED_TARGET_IDENTITY

set_identity beta develop
assert_installer_required 'beta -> develop at same commit' installer SAME_INSTALLED_TARGET_IDENTITY

set_identity beta beta
target_commit=0123456789abcdef0123456789abcdef01234567
assert_installer_required 'same branch with newer commit' installer SAME_INSTALLED_TARGET_IDENTITY

set_identity beta beta
target_beta=8
assert_installer_required 'same commit with newer beta sequence' installer SAME_INSTALLED_TARGET_IDENTITY

set_identity master master
assert_installer_required 'master true up to date' uptodate SAME_INSTALLED_TARGET_IDENTITY

installer_called=false
FETCH_REMOTE_VERSION() { printf '5.1.3'; }
FETCH_REMOTE_COMMIT() { printf '%s' "$REMOTE_COMMIT"; }
FETCH_REMOTE_BETA() { [[ "$BRANCH" == beta ]] && printf '7'; }
RUN_DOWNLOADED_INSTALLER() { installer_called=true; }
version_is_less() { return 1; }

run_update_gate() {
  local installed_branch=$1 target_branch=$2
  set_identity "$installed_branch" "$target_branch"
  LOCAL_FILES="$WORK_DIR/runtime"
  BUILD_METADATA_FILE="$LOCAL_FILES/build-metadata"
  mkdir -p "$LOCAL_FILES"
  printf 'VERSION="5.1.3"\n' > "$LOCAL_FILES/update.sh"
  printf 'branch="%s"\ncommit="%s"\nbeta="%s"\nversion="5.1.3"\n' \
    "$INSTALLED_BRANCH" "$INSTALLED_COMMIT" "$INSTALLED_BETA" > "$BUILD_METADATA_FILE"
  INSTALLED_BUILD_IDENTITY="5.1.3 $INSTALLED_BRANCH · 8915edf"
  installer_called=false
  REMOTE_COMMIT="$INSTALLED_COMMIT"
  target_beta=7
  UU_NONINTERACTIVE=true
  UPDATE >/dev/null
}

run_update_gate develop beta
if [[ "$installer_called" != true ]]; then
  echo 'FAIL: UPDATE() skipped develop -> beta transition' >&2
  exit 1
fi

run_update_gate beta beta
if [[ "$installer_called" == true ]]; then
  echo 'FAIL: UPDATE() ran installer for true beta up-to-date state' >&2
  exit 1
fi

grep -Fq 'UU_INTERACTIVE_INSTALLER=true' "$ROOT_DIR/update.sh"
grep -Fq 'Ultimate Updater $INSTALLED_BUILD_IDENTITY' "$ROOT_DIR/update.sh"
if grep -Fq 'Version: $installed_version' "$ROOT_DIR/update.sh"; then
  echo 'FAIL: stale up-to-date version output remains' >&2
  exit 1
fi

echo 'branch transition tests: PASS'
