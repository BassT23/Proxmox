#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

awk '/^UPDATE_FINAL_RC\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-final-rc.sh"
# shellcheck source=/dev/null
source "$WORK_DIR/update-final-rc.sh"

# shellcheck disable=SC2034
SAFETY_FAILURE=false
# shellcheck disable=SC2034
UPDATE_FAILURE=false
UPDATE_FINAL_RC 0
UPDATE_FAILURE=true
if UPDATE_FINAL_RC 0; then
  echo 'failed target was lost by final update aggregation' >&2
  exit 1
fi
# shellcheck disable=SC2034
UPDATE_FAILURE=false
if UPDATE_FINAL_RC 17; then
  echo 'non-zero command result was lost by final update aggregation' >&2
  exit 1
fi

awk '/^ERROR \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/error.sh"
: > "$WORK_DIR/errors"
CCONTAINER=false ID=913 NAME=fixture ERROR_CODE=17 ERROR_MSG='fixture failure' \
  ERROR_LOG_FILE="$WORK_DIR/errors" UPDATE_FAILURE=false \
  bash -c 'source "$1"; ERROR; [[ "$UPDATE_FAILURE" == true ]]' _ "$WORK_DIR/error.sh"

sed -n '/^HOST_CHECK_START () {/,/^# Host Check/p' "$ROOT_DIR/check-updates.sh" \
  | sed '$d' > "$WORK_DIR/check-loop.sh"
# shellcheck source=/dev/null
source "$WORK_DIR/check-loop.sh"
# shellcheck disable=SC2034
HOSTS='node1 node2 node3'
CHECK_FAILURE=0
checked_targets=()
HOST_IS_LOCAL() { return 1; }
CHECK_HOST() {
  checked_targets+=("$1")
  [[ "$1" == node2 ]] && return 19
  return 0
}
HOST_CHECK_START
[[ "$CHECK_FAILURE" -eq 1 ]]
[[ "${checked_targets[*]}" == 'node1 node2 node3' ]]

LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD host:node3 host ssh false "" "" null null offline NODE_OFFLINE "fixture"
    STATUS_MODEL_HAS_FAILURES
  ' _ "$ROOT_DIR/status-model.sh"
LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json" \
  STATUS_MODEL_RECORD_FILE="$WORK_DIR/status.records" bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD guest:910 lxc pct true debian apt 0 false ok
    if STATUS_MODEL_HAS_FAILURES; then exit 1; fi
  ' _ "$ROOT_DIR/status-model.sh"

awk '/^CHECK_CONTAINER_FAILURE\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-container-failure.sh"
CHECK_FAILURE=0 CONTAINER=912 OS=debian recorded_status='' \
  bash -c '
    STATUS_MODEL_RECORD() { recorded_status="$9"; }
    source "$1"
    CHECK_CONTAINER_FAILURE "timeout fixture" || true
    [[ "$CHECK_FAILURE" -eq 1 && "$recorded_status" == error ]]
  ' _ "$WORK_DIR/check-container-failure.sh"

awk '/^ARGUMENTS \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/arguments.sh"
CHECK_FAILURE=0
OUTPUT_TO_FILE() { :; }
CHECK_VM() { return 1; }
CHECK_CONTAINER() { return 1; }
CHECK_HOST_ITSELF() { return 1; }
# shellcheck disable=SC1091
source "$WORK_DIR/arguments.sh"
ARGUMENTS cvm 391
[[ "$CHECK_FAILURE" -eq 1 ]]

sed -n '/^single_check_result() {/,/^}/{p}' "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/single-check-result.sh"

STATUS_MODEL_RECORD_FILE="$WORK_DIR/remote-status.records" \
  bash -c '
    source "$1"
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 391 vm qga false "" "" null null error QGA_TRANSPORT "fixture"
    source "$2"
    if single_check_result 0; then exit 1; fi
    STATUS_MODEL_INIT
    STATUS_MODEL_RECORD 100 vm ssh true FreeBSD "" null null unsupported UNSUPPORTED_OS "fixture"
    single_check_result 0
  ' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/single-check-result.sh"

echo 'exit aggregation tests: PASS'
