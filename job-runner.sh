#!/bin/bash

# Session-independent execution boundary for the existing updater.
# Only the fixed "run" action is executed by systemd; target validation and
# update policy remain in the regular CLI/updater scripts.

set -o pipefail

JOB_STATE_DIR="${UU_JOB_STATE_DIR:-/var/lib/ultimate-updater/jobs}"
JOB_PREFIX="ultimate-updater-update-"
RUNNER_PATH=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

usage() {
  printf 'Usage: %s start UPDATE_SCRIPT TARGET | run UNIT TARGET UPDATE_SCRIPT | list\n' "$0"
}

valid_target() {
  case "$1" in
    host|local-host|[0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

safe_unit_target() {
  case "$1" in
    host) printf 'host' ;;
    local-host) printf 'local-host' ;;
    *) printf '%s' "$1" | tr -cd '[:alnum:]_' ;;
  esac
}

now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

state_file() {
  printf '%s/%s.state' "$JOB_STATE_DIR" "$1"
}

state_value() {
  local file="$1" key="$2"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' "$file"
}

write_state() {
  local unit="$1" target="$2" state="$3" started="$4" finished="$5"
  local exit_code="$6" message="${7:-}" file temp
  file=$(state_file "$unit")
  temp="$file.tmp.$$"
  {
    printf 'schema_version=1\n'
    printf 'unit=%s\n' "$unit"
    printf 'target=%s\n' "$target"
    printf 'state=%s\n' "$state"
    printf 'started_at=%s\n' "$started"
    printf 'finished_at=%s\n' "$finished"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'message=%s\n' "$message"
  } > "$temp" || return 1
  chmod 0644 "$temp" || return 1
  mv -f -- "$temp" "$file"
}

ensure_state_dir() {
  mkdir -p "$JOB_STATE_DIR" || return 1
  chmod 0755 "$JOB_STATE_DIR" || return 1
}

target_running() {
  local file target state
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    if [[ "$target" == "$1" && "$state" == running ]]; then
      return 0
    fi
  done
  return 1
}

start_job() {
  local update_script="$1" target="$2" unit timestamp
  [[ -x "$update_script" ]] || { printf 'Update script is not executable: %s\n' "$update_script" >&2; return 1; }
  valid_target "$target" || { printf 'Unsupported target: %s\n' "$target" >&2; return 2; }
  command -v systemd-run >/dev/null 2>&1 || { printf 'systemd-run is required to start update jobs.\n' >&2; return 5; }
  [[ "$EUID" -eq 0 ]] || { printf 'Starting update jobs requires root.\n' >&2; return 2; }
  ensure_state_dir || { printf 'Cannot prepare job state directory: %s\n' "$JOB_STATE_DIR" >&2; return 1; }
  if target_running "$target"; then
    printf 'An update job is already running for target %s.\n' "$target" >&2
    return 3
  fi

  timestamp=$(date -u '+%Y%m%d-%H%M%S')
  unit="${JOB_PREFIX}$(safe_unit_target "$target")-$timestamp-$BASHPID"
  write_state "$unit" "$target" running "$(now)" '' '' || return 1
  if ! systemd-run --no-block --unit="$unit" --description="Ultimate Updater update for $target" \
    --setenv=UU_JOB_STATE_DIR="$JOB_STATE_DIR" \
    --property=Type=oneshot --property=StandardOutput=journal \
    --property=StandardError=journal "$RUNNER_PATH" run "$unit" "$target" "$update_script"; then
    write_state "$unit" "$target" failed "$(state_value "$(state_file "$unit")" started_at)" "$(now)" 1 "systemd-run failed" || true
    return 1
  fi
  printf 'Update job started\nTarget: %s\nJob: %s\nStatus: ultimate-updater status\nLogs: journalctl -u %s\n' \
    "$target" "$unit" "$unit"
}

run_job() {
  local unit="$1" target="$2" update_script="$3" file started exit_code lock_file
  valid_target "$target" || return 2
  file=$(state_file "$unit")
  started=$(state_value "$file" started_at)
  command -v flock >/dev/null 2>&1 || {
    write_state "$unit" "$target" failed "$started" "$(now)" 5 "flock is unavailable"
    return 5
  }
  lock_file="$JOB_STATE_DIR/$target.lock"
  exec 9>"$lock_file" || {
    write_state "$unit" "$target" failed "$started" "$(now)" 1 "could not open target lock"
    return 1
  }
  if ! flock -n 9; then
    write_state "$unit" "$target" failed "$started" "$(now)" 75 "target update already locked"
    return 75
  fi
  "$update_script" "$target" </dev/null
  exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    write_state "$unit" "$target" completed "$started" "$(now)" "$exit_code" || return 1
  else
    write_state "$unit" "$target" failed "$started" "$(now)" "$exit_code" || return 1
  fi
  return "$exit_code"
}

refresh_running_jobs() {
  local file unit target state
  command -v systemctl >/dev/null 2>&1 || return 0
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    if [[ "$state" == running ]] && ! systemctl is-active --quiet "$unit" 2>/dev/null; then
      write_state "$unit" "$target" interrupted "$(state_value "$file" started_at)" "$(now)" '' "unit no longer active" || true
    fi
  done
}

list_jobs() {
  [[ -d "$JOB_STATE_DIR" ]] || return 0
  refresh_running_jobs
  local file unit target state started finished exit_code
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    started=$(state_value "$file" started_at)
    finished=$(state_value "$file" finished_at)
    exit_code=$(state_value "$file" exit_code)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$unit" "$target" "$state" "$started" "$finished" "$exit_code"
  done
}

case "${1:-}" in
  start)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start_job "$2" "$3"
    ;;
  run)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    run_job "$2" "$3" "$4"
    ;;
  list)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    list_jobs
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
