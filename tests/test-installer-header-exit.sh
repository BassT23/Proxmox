#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_ROOT/install.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

assert_contains() {
  local file=$1
  local text=$2
  grep -Fq "$text" "$file"
}

run_help() {
  local output=$1
  shift
  set +e
  "$@" bash "$WORK_DIR/success.sh" -h >"$output" 2>&1
  local rc=$?
  set -e
  [[ "$rc" -eq 0 ]]
  assert_contains "$output" "*** Install and/or Update ***"
  assert_contains "$output" "Version :   2.1"
}

cp "$INSTALLER" "$WORK_DIR/success.sh"
sed -i '0,/^  CHECK_ROOT$/s//  :/' "$WORK_DIR/success.sh"

run_help "$WORK_DIR/xterm.out" env TERM=xterm-256color
run_help "$WORK_DIR/dumb.out" env TERM=dumb
run_help "$WORK_DIR/unset.out" env -u TERM
run_help "$WORK_DIR/noninteractive.out" env TERM=dumb

cp "$INSTALLER" "$WORK_DIR/early-failure.sh"
sed -i '0,/^HEADER_INFO$/s//false/' "$WORK_DIR/early-failure.sh"
set +e
TERM=dumb bash "$WORK_DIR/early-failure.sh" -h >"$WORK_DIR/failure.out" 2>&1
failure_rc=$?
set -e
[[ "$failure_rc" -eq 1 ]]
assert_contains "$WORK_DIR/failure.out" "Error during install --- Exit Code: 1"
if grep -Fq "*** Install and/or Update ***" "$WORK_DIR/failure.out"; then
  echo "early failure unexpectedly emitted the banner" >&2
  exit 1
fi

cp "$INSTALLER" "$WORK_DIR/cleanup-failure.sh"
sed -i '0,/^HEADER_INFO$/s//false/' "$WORK_DIR/cleanup-failure.sh"
sed -i '/^set -e$/a rm() { return 1; }' "$WORK_DIR/cleanup-failure.sh"
set +e
TERM=dumb bash "$WORK_DIR/cleanup-failure.sh" -h >"$WORK_DIR/cleanup.out" 2>&1
cleanup_rc=$?
set -e
[[ "$cleanup_rc" -eq 1 ]]
assert_contains "$WORK_DIR/cleanup.out" "Error during install --- Exit Code: 1"

echo "installer header and exit-code tests passed"
