#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

run_case() {
  local mode="$1" log_file="$2" terminal_file="$3" expected_rc="$4"
  (
    set -euo pipefail
    export RICM=false
    LOG_FILE="$log_file"
    TEMP_STATE_DIR="$WORK_DIR/state-$mode"
    LOCAL_FILES="$WORK_DIR/files-$mode"
    mkdir -p -- "$TEMP_STATE_DIR" "$LOCAL_FILES"
    : > "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    # shellcheck disable=SC1090
    source <(sed -n '/^# Logging$/,/^# Error handling$/ { /^# Error handling$/d; p; }' "$ROOT_DIR/update.sh")
    OUTPUT_TO_FILE
    printf 'discarded-first-line\n'
    case "$mode" in
      success|warning|error)
        printf 'BEGIN-MARKER\n'
        index=1
        while (( index <= 12000 )); do
          printf 'PAYLOAD-%06d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$index"
          index=$((index + 1))
        done
        printf '\033[31mANSI-MIDDLE-MARKER\033[0m\n'
        while (( index <= 24000 )); do
          printf 'PAYLOAD-%06d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$index"
          index=$((index + 1))
        done
        printf 'END-MARKER\n'
        ;;
      short)
        printf 'SHORT-MARKER\n'
        ;;
      empty)
        :
        ;;
    esac
    CLEAN_LOGFILE
    exit "$expected_rc"
  ) > "$terminal_file" 2>&1
}

assert_large_case() {
  local mode="$1" expected_rc="$2" log_file terminal_file
  log_file="$WORK_DIR/$mode.log"
  terminal_file="$WORK_DIR/$mode.terminal"
  local expected_owner expected_mode actual_owner actual_mode
  expected_owner=$(stat -c '%u:%g' "$log_file")
  expected_mode=$(stat -c '%a' "$log_file")
  if run_case "$mode" "$log_file" "$terminal_file" "$expected_rc"; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" -eq "$expected_rc" ]]
  [[ -s "$terminal_file" ]]
  grep -Fq 'BEGIN-MARKER' "$terminal_file"
  grep -Fq 'ANSI-MIDDLE-MARKER' "$terminal_file"
  grep -Fq 'END-MARKER' "$terminal_file"
  [[ "$(grep -c '^PAYLOAD-' "$terminal_file")" -eq 24000 ]]
  [[ "$(grep -c '^PAYLOAD-' "$log_file")" -eq 24000 ]]
  grep -Fq 'BEGIN-MARKER' "$log_file"
  grep -Fq 'ANSI-MIDDLE-MARKER' "$log_file"
  grep -Fq 'END-MARKER' "$log_file"
  if grep -q $'\033' "$log_file"; then
    return 1
  fi
  [[ "$(wc -c < "$log_file")" -ge 1000000 ]]
  actual_owner=$(stat -c '%u:%g' "$log_file")
  actual_mode=$(stat -c '%a' "$log_file")
  [[ "$actual_owner" == "$expected_owner" ]]
  [[ "$actual_mode" == "$expected_mode" ]]
  if compgen -G "${log_file}.raw.*" >/dev/null || compgen -G "${log_file}.clean.*" >/dev/null; then
    return 1
  fi
}

for case_spec in 'success 0' 'warning 10' 'error 7'; do
  read -r case_name case_rc <<< "$case_spec"
  log_file="$WORK_DIR/$case_name.log"
  : > "$log_file"
  chmod 640 "$log_file"
  assert_large_case "$case_name" "$case_rc"
done

for case_name in short empty; do
  log_file="$WORK_DIR/$case_name.log"
  terminal_file="$WORK_DIR/$case_name.terminal"
  : > "$log_file"
  chmod 640 "$log_file"
  if run_case "$case_name" "$log_file" "$terminal_file" 0; then
    actual_rc=0
  else
    actual_rc=$?
  fi
  [[ "$actual_rc" -eq 0 ]]
  [[ "$(stat -c '%a' "$log_file")" == 640 ]]
  if compgen -G "${log_file}.raw.*" >/dev/null || compgen -G "${log_file}.clean.*" >/dev/null; then
    exit 1
  fi
done

echo 'update log cleanup regression tests: PASS'
