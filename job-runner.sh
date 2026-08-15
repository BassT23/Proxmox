#!/bin/bash

# Session-independent execution boundary for the existing updater.
# Only the fixed "run" action is executed by systemd; target validation and
# update policy remain in the regular CLI/updater scripts.

set -o pipefail

JOB_STATE_DIR="${UU_JOB_STATE_DIR:-/var/lib/ultimate-updater/jobs}"
REMOTE_REF_DIR="$JOB_STATE_DIR/remote"
JOB_PREFIX="ultimate-updater-update-"
RUNNER_PATH=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")

usage() {
  printf 'Usage: %s start UPDATE_SCRIPT TARGET | run UNIT TARGET UPDATE_SCRIPT | list\n' "$0"
}

valid_target() {
  case "$1" in
    host|local-host|[A-Za-z0-9][A-Za-z0-9_.-]*) return 0 ;;
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

remote_ref_file() {
  printf '%s/%s.ref' "$REMOTE_REF_DIR" "$1"
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

valid_unit() {
  [[ "$1" =~ ^ultimate-updater-update-[A-Za-z0-9_.-]+$ ]]
}

valid_remote_value() {
  [[ -n "$1" && "$1" != *[!A-Za-z0-9_.:-]* ]]
}

write_remote_ref() {
  local unit="$1" target="$2" owner_node="$3" owner_host="$4" port="$5" file temp
  valid_unit "$unit" || return 2
  valid_target "$target" || return 2
  valid_remote_value "$owner_node" || return 2
  valid_remote_value "$owner_host" || return 2
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || return 2
  mkdir -p "$REMOTE_REF_DIR" || return 1
  chmod 0755 "$REMOTE_REF_DIR" || return 1
  file=$(remote_ref_file "$unit")
  temp="$file.tmp.$$"
  {
    printf 'schema_version=1\n'
    printf 'unit=%s\n' "$unit"
    printf 'target=%s\n' "$target"
    printf 'owner_node=%s\n' "$owner_node"
    printf 'owner_host=%s\n' "$owner_host"
    printf 'port=%s\n' "$port"
  } > "$temp" || return 1
  chmod 0644 "$temp" || return 1
  mv -f -- "$temp" "$file"
}

remote_ref_line() {
  local unit="$1" file
  valid_unit "$unit" || return 2
  file=$(remote_ref_file "$unit")
  [[ -f "$file" ]] || return 1
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(state_value "$file" unit)" "$(state_value "$file" target)" \
    "$(state_value "$file" owner_node)" "$(state_value "$file" owner_host)" \
    "$(state_value "$file" port)"
}

remote_state_line() {
  local unit="$1" target="$2" owner_node="$3" owner_host="$4" port="$5" output
  if ! output=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$owner_host" \
      /etc/ultimate-updater/job-runner.sh list 2>/dev/null); then
    printf '%s\t%s\tremote_unavailable\t\t\t\t%s\n' "$unit" "$target" "$owner_node"
    return 0
  fi
  if awk -F '\t' -v wanted="$unit" -v owner="$owner_node" \
      '$1 == wanted { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" owner; found=1; exit } END { exit(found ? 0 : 1) }' \
      <<< "$output"; then
    return 0
  fi
  printf '%s\t%s\tremote_unavailable\t\t\t\t%s\n' "$unit" "$target" "$owner_node"
}

sync_remote_last_update() {
  local target="$1" state="$2" finished="$3" exit_code="$4"
  [[ "$state" == completed || "$state" == failed || "$state" == interrupted ]] || return 0
  [[ "$target" =~ ^[0-9]+$ ]] || return 0
  [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=1
  python3 - "${UU_STATUS_MODEL_FILE:-/etc/ultimate-updater/status.json}" \
    "$target" "$state" "$finished" "$exit_code" <<'PY'
import json
import os
import sys
import tempfile

status_file, target_id, job_state, finished, exit_code = sys.argv[1:]
try:
    with open(status_file, encoding="utf-8") as source:
        payload = json.load(source)
except (FileNotFoundError, OSError, ValueError):
    return_code = 0
    raise SystemExit(return_code)

targets = payload.get("targets") if isinstance(payload, dict) else None
if not isinstance(targets, list):
    raise SystemExit(0)
record = next((item for item in targets
               if isinstance(item, dict) and str(item.get("id")) == target_id), None)
if record is None:
    raise SystemExit(0)

status = "success" if job_state == "completed" and exit_code == "0" else "failed"
record["last_update"] = {
    "status": status,
    "timestamp": finished or None,
    "exit_code": int(exit_code),
}
directory = os.path.dirname(os.path.abspath(status_file)) or "."
fd, temporary = tempfile.mkstemp(prefix=".status.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, indent=2)
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.chmod(temporary, 0o644)
    os.replace(temporary, status_file)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
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
  local file unit target state active_state load_state started age_seconds
  command -v systemctl >/dev/null 2>&1 || return 0
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    if [[ "$state" == running ]]; then
      # A transient unit can be briefly invisible between the state file
      # write and systemd registering the unit.  Do not turn that startup
      # window into a false interrupted state.
      active_state=""
      load_state=""
      while IFS= read -r line; do
        case "$line" in
          ActiveState=*) active_state=${line#ActiveState=} ;;
          LoadState=*) load_state=${line#LoadState=} ;;
        esac
      done < <(systemctl show "$unit" -p ActiveState -p LoadState 2>/dev/null || true)
      case "$active_state" in
        active|activating|deactivating) ;;
        *)
          if [[ "$load_state" != loaded ]]; then
            started=$(state_value "$file" started_at)
            age_seconds=$(( $(date -u +%s) - $(date -u -d "$started" +%s 2>/dev/null || date -u +%s) ))
            if (( age_seconds >= 30 )); then
              write_state "$unit" "$target" interrupted "$started" "$(now)" '' "unit no longer active" || true
            fi
          fi
          ;;
      esac
    fi
  done
}

list_jobs() {
  [[ -d "$JOB_STATE_DIR" ]] || return 0
  refresh_running_jobs
  local file unit target state started finished exit_code owner_node owner_host port
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    started=$(state_value "$file" started_at)
    finished=$(state_value "$file" finished_at)
    exit_code=$(state_value "$file" exit_code)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t\n' "$unit" "$target" "$state" "$started" "$finished" "$exit_code"
  done
  shopt -s nullglob
  for file in "$REMOTE_REF_DIR"/*.ref; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    owner_node=$(state_value "$file" owner_node)
    owner_host=$(state_value "$file" owner_host)
    port=$(state_value "$file" port)
    [[ -n "$unit" && -n "$target" && -n "$owner_node" && -n "$owner_host" && -n "$port" ]] || continue
    remote_state=$(remote_state_line "$unit" "$target" "$owner_node" "$owner_host" "$port")
    printf '%s\n' "$remote_state"
    IFS=$'\t' read -r _ remote_target remote_status _ remote_finished remote_exit _ <<< "$remote_state"
    sync_remote_last_update "$remote_target" "$remote_status" "$remote_finished" "$remote_exit" || true
  done
}

remote_log() {
  local unit="$1" ref_line target owner_node owner_host port remote_command
  ref_line=$(remote_ref_line "$unit") || { printf 'Remote job reference not found: %s\n' "$unit" >&2; return 1; }
  IFS=$'\t' read -r unit target owner_node owner_host port <<< "$ref_line"
  printf -v remote_command 'journalctl -u %q -n 200 --no-pager -o cat' "$unit"
  ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$owner_host" "$remote_command"
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
  record-remote)
    [[ $# -eq 6 ]] || { usage >&2; exit 2; }
    write_remote_ref "$2" "$3" "$4" "$5" "$6"
    ;;
  remote-log)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    remote_log "$2"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
