#!/bin/bash

set -euo pipefail

HARDCORE_ROOT="${UU_HARDCORE_TEST_ROOT:-/var/lib/ultimate-updater/hardcore-tests}"
CURRENT_FILE="$HARDCORE_ROOT/current"

usage() {
  cat >&2 <<EOF
Usage: $0 start [PHASE] [DESCRIPTION]
       $0 status [RUN_ID]
       $0 stop [RUN_ID]
       $0 progress RUN_ID PHASE CURRENT_TEST
       $0 log RUN_ID TEST_ID AREA TARGET INITIAL FAULT EXPECTED ACTUAL RESULT BUG_ID FIX_COMMIT RETEST CLEANUP
       $0 finalize RUN_ID RESULT REASON
       $0 list
EOF
}

valid_run_id() {
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]]
}

run_dir() {
  local run_id="$1"
  valid_run_id "$run_id" || { printf 'Invalid hardcore test run ID.\n' >&2; return 64; }
  printf '%s/%s\n' "$HARDCORE_ROOT" "$run_id"
}

field() {
  local file="$1" key="$2"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

atomic_write() {
  local target="$1" directory temporary
  directory=${target%/*}
  install -d -m 0750 "$directory"
  temporary=$(mktemp "$target.tmp.XXXXXX")
  cat > "$temporary"
  chmod 0640 "$temporary"
  mv -f "$temporary" "$target"
}

write_state() {
  local directory="$1" status="$2" phase="$3" current_test="$4" reason="${5:-}"
  local state_file="$directory/state"
  atomic_write "$state_file" <<EOF
run_id=$(basename "$directory")
status=$status
started=$(field "$state_file" started 2>/dev/null || date +%s)
updated=$(date +%s)
phase=$phase
current_test=$current_test
reason=$reason
EOF
}

read_run_id() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
  else
    [[ -r "$CURRENT_FILE" ]] || { printf 'No hardcore test run exists.\n' >&2; return 1; }
    tr -d '[:space:]' < "$CURRENT_FILE"
  fi
}

run_start() {
  local phase="${1:-baseline}" description="${2:-}" run_id directory existing status
  install -d -m 0750 "$HARDCORE_ROOT"
  if [[ -r "$CURRENT_FILE" ]]; then
    existing=$(read_run_id)
    directory=$(run_dir "$existing")
    if [[ -r "$directory/state" ]]; then
      status=$(field "$directory/state" status)
      if [[ "$status" == running || "$status" == stopping ]]; then
        printf 'A hardcore test is already active: %s\n' "$existing" >&2
        return 1
      fi
    fi
  fi
  run_id=$(date -u +%Y%m%d-%H%M%S)
  directory=$(run_dir "$run_id")
  if [[ -e "$directory" ]]; then
    run_id="${run_id}-$$"
    directory=$(run_dir "$run_id")
  fi
  install -d -m 0750 "$directory"
  atomic_write "$directory/state" <<EOF
run_id=$run_id
status=running
started=$(date +%s)
updated=$(date +%s)
phase=$phase
current_test=$description
reason=
EOF
  : > "$directory/journal.tsv"
  chmod 0640 "$directory/journal.tsv"
  atomic_write "$CURRENT_FILE" <<EOF
$run_id
EOF
  printf 'RUN_ID=%s\nPATH=%s\n' "$run_id" "$directory"
}

run_log() {
  [[ $# -eq 13 ]] || { usage; return 2; }
  local directory
  directory=$(run_dir "$1")
  [[ -f "$directory/state" && -f "$directory/journal.tsv" ]] || { printf 'Unknown hardcore test run: %s\n' "$1" >&2; return 1; }
  local value
  for value in "${@:2}"; do
    [[ "$value" != *$'\t'* && "$value" != *$'\n'* ]] || { printf 'Journal values may not contain tabs or newlines.\n' >&2; return 64; }
  done
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${@:2}" >> "$directory/journal.tsv"
}

run_status() {
  local run_id directory state journal pass fail bugs started now elapsed
  run_id=$(read_run_id "${1:-}")
  directory=$(run_dir "$run_id")
  state="$directory/state"
  journal="$directory/journal.tsv"
  [[ -r "$state" ]] || { printf 'Unknown hardcore test run: %s\n' "$run_id" >&2; return 1; }
  started=$(field "$state" started)
  now=$(date +%s)
  elapsed=$((now - started))
  pass=$(awk -F '\t' '$9 == "PASS" {n++} END {print n+0}' "$journal")
  fail=$(awk -F '\t' '$9 == "FAIL" {n++} END {print n+0}' "$journal")
  bugs=$(awk -F '\t' '$10 != "" && $10 != "-" {n++} END {print n+0}' "$journal")
  printf 'Run ID: %s\n' "$run_id"
  printf 'Status: %s\n' "$(field "$state" status)"
  printf 'Started: %s\n' "$(field "$state" started)"
  printf 'Elapsed: %ss\n' "$elapsed"
  printf 'Phase: %s\n' "$(field "$state" phase)"
  printf 'Current test: %s\n' "$(field "$state" current_test)"
  printf 'PASS: %s\nFAIL: %s\nBugs: %s\n' "$pass" "$fail" "$bugs"
}

run_stop() {
  local run_id directory status
  run_id=$(read_run_id "${1:-}")
  directory=$(run_dir "$run_id")
  status=$(field "$directory/state" status)
  [[ "$status" == running ]] || { printf 'Run is not active: %s\n' "$run_id" >&2; return 1; }
  : > "$directory/STOP"
  chmod 0640 "$directory/STOP"
  write_state "$directory" stopping "$(field "$directory/state" phase)" "$(field "$directory/state" current_test)" "owner stop requested"
  printf 'Stop requested for %s.\n' "$run_id"
}

run_progress() {
  [[ $# -eq 3 ]] || { usage; return 2; }
  local directory status reason
  directory=$(run_dir "$1")
  [[ -r "$directory/state" ]] || { printf 'Unknown hardcore test run: %s\n' "$1" >&2; return 1; }
  status=$(field "$directory/state" status)
  [[ "$status" == running || "$status" == stopping ]] || { printf 'Run is not active: %s\n' "$1" >&2; return 1; }
  reason=$(field "$directory/state" reason)
  write_state "$directory" "$status" "$2" "$3" "$reason"
}

run_finalize() {
  [[ $# -eq 3 ]] || { usage; return 2; }
  local directory
  directory=$(run_dir "$1")
  [[ -f "$directory/state" ]] || { printf 'Unknown hardcore test run: %s\n' "$1" >&2; return 1; }
  case "$2" in completed|aborted|critical-abort) ;; *) printf 'Invalid final status.\n' >&2; return 64 ;; esac
  write_state "$directory" "$2" "cleanup" "" "$3"
  printf 'Run %s finalized as %s.\n' "$1" "$2"
}

run_list() {
  [[ -d "$HARDCORE_ROOT" ]] || return 0
  for directory in "$HARDCORE_ROOT"/20*; do
    [[ -r "$directory/state" ]] || continue
    printf '%s\t%s\t%s\n' "$(basename "$directory")" "$(field "$directory/state" status)" "$(field "$directory/state" started)"
  done
}

case "${1:-}" in
  start) [[ $# -le 3 ]] || { usage; exit 2; }; run_start "${2:-baseline}" "${3:-}" ;;
  status) [[ $# -le 2 ]] || { usage; exit 2; }; run_status "${2:-}" ;;
  stop) [[ $# -le 2 ]] || { usage; exit 2; }; run_stop "${2:-}" ;;
  progress) shift; run_progress "$@" ;;
  log) shift; run_log "$@" ;;
  finalize) shift; run_finalize "$@" ;;
  list) [[ $# -eq 1 ]] || { usage; exit 2; }; run_list ;;
  *) usage; exit 2 ;;
esac
