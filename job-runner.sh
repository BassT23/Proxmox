#!/bin/bash

# Session-independent execution boundary for the existing updater.
# Only the fixed "run" action is executed by systemd; target validation and
# update policy remain in the regular CLI/updater scripts.

set -o pipefail

JOB_STATE_DIR="${UU_JOB_STATE_DIR:-/var/lib/ultimate-updater/jobs}"
REMOTE_REF_DIR="$JOB_STATE_DIR/remote"
JOB_PREFIX="ultimate-updater-update-"
CHECK_PREFIX="ultimate-updater-check-"
MAX_COMPLETED_JOBS="${UU_MAX_COMPLETED_JOBS:-50}"
CHECK_SCRIPT="${UU_CHECK_SCRIPT:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/check-updates.sh}"
CHECK_CLI="${UU_CHECK_CLI:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/ultimate-updater}"
STATUS_MODEL_SCRIPT="${UU_STATUS_MODEL_SCRIPT:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/status-model.sh}"
STATUS_MODEL_FILE="${UU_STATUS_MODEL_FILE:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/status.json}"
UPDATE_CONFIG_FILE="${UU_UPDATE_CONFIG_FILE:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/update.conf}"
REMOTE_JOB_STATE_DIR="${UU_REMOTE_JOB_STATE_DIR:-/var/lib/ultimate-updater/jobs}"
RUNNER_PATH=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
SYSTEMD_LOG_FILTER_ARGS=()

usage() {
  printf 'Usage: %s start UPDATE_SCRIPT TARGET | start-global UPDATE_SCRIPT | start-check TARGET CLI MODE | start-selfupdate UPDATE_SCRIPT BRANCH | run UNIT TARGET UPDATE_SCRIPT | run-global UNIT UPDATE_SCRIPT | run-check UNIT TARGET CLI MODE | run-selfupdate UNIT BRANCH UPDATE_SCRIPT | list\n' "$0"
}

valid_target() {
  case "$1" in
    host|local-host|[A-Za-z0-9][A-Za-z0-9_.-]*) return 0 ;;
    *) return 1 ;;
  esac
}

valid_global_target() {
  [[ "$1" == all-systems ]]
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

configured_debug_enabled() {
  local value="${DEBUG:-}"
  if [[ -z "$value" && -f "$UPDATE_CONFIG_FILE" ]]; then
    value=$(awk -F= '$1 == "DEBUG" { sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); gsub(/^"|"$/, "", $2); gsub(/^\x27|\x27$/, "", $2); print $2; exit }' \
      "$UPDATE_CONFIG_FILE" 2>/dev/null || true)
  fi
  [[ "${value,,}" == true || "${value,,}" == 1 || "${value,,}" == yes ]]
}

prepare_systemd_log_filters() {
  SYSTEMD_LOG_FILTER_ARGS=()
  configured_debug_enabled && return 0

  # Proxmox task clients write these messages directly to journald. They do
  # not travel through pct/qm stdout/stderr, so shell redirection cannot hide
  # them. Keep the filter narrow and unit-local; DEBUG=true leaves the full
  # journal untouched.
  SYSTEMD_LOG_FILTER_ARGS+=(
    '--property=LogFilterPatterns=~^<root@pam> (starting task UPID:|end task UPID:|.*UPID:).*'
    '--property=LogFilterPatterns=~^<root@pam> (snapshot|delete snapshot) (container|VM) [^:]+:.*'
    '--property=LogFilterPatterns=~^(starting|shutdown) (CT|VM) [^:]+: UPID:.*'
    '--property=LogFilterPatterns=~^push_file([[:space:]]|$).*'
  )
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
  local exit_code="$6" message="${7:-}" type="${8:-${UU_JOB_TYPE:-update}}"
  local source="${9:-${UU_JOB_SOURCE:-}}" file temp
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
    printf 'type=%s\n' "$type"
    printf 'message=%s\n' "$message"
    printf 'source=%s\n' "$source"
  } > "$temp" || return 1
  chmod 0644 "$temp" || return 1
  mv -f -- "$temp" "$file"
  case "$state" in
    completed|failed|interrupted) cleanup_completed_jobs || true ;;
  esac
}

ensure_state_dir() {
  mkdir -p "$JOB_STATE_DIR" || return 1
  chmod 0755 "$JOB_STATE_DIR" || return 1
  cleanup_completed_jobs || true
}

valid_unit() {
  [[ "$1" =~ ^ultimate-updater-(update|check)-[A-Za-z0-9_.-]+$ ]]
}

valid_remote_value() {
  [[ -n "$1" && "$1" != *[!A-Za-z0-9_.:-]* ]]
}

write_remote_ref() {
  local unit="$1" target="$2" owner_node="$3" owner_host="$4" port="$5" workspace="${6:-}" file temp
  valid_unit "$unit" || return 2
  valid_target "$target" || return 2
  valid_remote_value "$owner_node" || return 2
  valid_remote_value "$owner_host" || return 2
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]] || return 2
  [[ -z "$workspace" || "$workspace" =~ ^/tmp/ultimate-updater-update-node-[0-9]+-[0-9]+-[0-9]+$ ]] || return 2
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
    printf 'registered_at=%s\n' "$(now)"
    printf 'status_refresh=pending\n'
    printf 'workspace=%s\n' "$workspace"
  } > "$temp" || return 1
  chmod 0644 "$temp" || return 1
  mv -f -- "$temp" "$file"
}

mark_remote_status_refresh() {
  local unit="$1" result="$2" file temp
  file=$(remote_ref_file "$unit")
  [[ -f "$file" ]] || return 1
  temp="$file.tmp.$$"
  awk -F= -v result="$result" '$1 != "status_refresh" { print } END { print "status_refresh=" result }' \
    "$file" > "$temp" || return 1
  chmod 0644 "$temp" || return 1
  mv -f -- "$temp" "$file"
}

refresh_remote_target_status() {
  local unit="$1" owner_node="$2" target="$3" refresh_state refresh_rc=0 lock
  local ref_file workspace local_status_file remote_refresh_rc remote_status_file
  ref_file=$(remote_ref_file "$unit")
  refresh_state=$(state_value "$ref_file" status_refresh)
  [[ "$refresh_state" == "done" || "$refresh_state" == "failed" ]] && return 0
  lock="$ref_file.refresh.lock"
  mkdir "$lock" 2>/dev/null || return 0
  workspace=$(state_value "$ref_file" workspace)
  if [[ "$target" =~ ^[0-9]+$ && -n "$workspace" && -x "$CHECK_CLI" ]]; then
    local_status_file=$(mktemp)
    remote_status_file="$workspace/status.json"
    if ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$(state_value "$ref_file" port)" \
      "$(state_value "$ref_file" owner_host)" "cat $(printf '%q' "$remote_status_file")" > "$local_status_file" 2>/dev/null &&
      [[ -s "$local_status_file" ]] &&
      validate_status_target "$local_status_file" "$target" &&
      "$CHECK_CLI" status-import "$local_status_file" </dev/null &&
      validate_status_target "$STATUS_MODEL_FILE" "$target"; then
      remote_refresh_rc=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$(state_value "$ref_file" port)" \
        "$(state_value "$ref_file" owner_host)" "cat $(printf '%q' "$workspace/post-update-status.rc")" 2>/dev/null || printf '0')
      [[ "$remote_refresh_rc" =~ ^[0-9]+$ ]] || remote_refresh_rc=1
      refresh_rc="$remote_refresh_rc"
      ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$(state_value "$ref_file" port)" \
        "$(state_value "$ref_file" owner_host)" "rm -rf -- $(printf '%q' "$workspace")" >/dev/null 2>&1 || true
    else
      refresh_rc=1
    fi
    rm -f -- "$local_status_file"
  elif [[ -x "$CHECK_CLI" ]]; then
    if [[ "$target" == node-* ]]; then
      UU_CHECK_JOB_EXECUTION=true UU_DEFER_NOTIFICATION=true "$CHECK_CLI" check-node "$owner_node" </dev/null || refresh_rc=$?
    else
      UU_CHECK_JOB_EXECUTION=true UU_DEFER_NOTIFICATION=true "$CHECK_CLI" check "$target" </dev/null || refresh_rc=$?
    fi
  else
    refresh_rc=127
  fi
  if [[ "$refresh_rc" -eq 0 ]]; then
    mark_remote_status_refresh "$unit" "done" || true
  else
    mark_remote_status_refresh "$unit" "failed" || true
    printf 'Remote post-update status refresh failed for %s (exit code %s).\n' \
      "$target" "$refresh_rc" >&2
  fi
  rmdir "$lock" 2>/dev/null || true
  return 0
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
  local unit="$1" target="$2" owner_node="$3" owner_host="$4" port="$5" output remote_line
  local remote_state_file="$REMOTE_JOB_STATE_DIR/$unit.state"
  local ref_file registered_at
  ref_file=$(remote_ref_file "$unit")
  registered_at=$(state_value "$ref_file" registered_at)
  printf -v remote_command 'if [[ -f %q ]]; then cat %q; else exit 1; fi' \
    "$remote_state_file" "$remote_state_file"
  if output=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$owner_host" \
      "$remote_command" 2>/dev/null); then
    remote_line=$(awk -F= -v owner="$owner_node" '
      { values[$1]=$0; sub(/^[^=]*=/, "", values[$1]) }
      END {
        if (values["unit"] == "") exit 1
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", values["unit"], values["target"],
          values["state"], values["started_at"], values["finished_at"], values["exit_code"], owner
      }' <<< "$output") || remote_line=""
    if [[ -n "$remote_line" ]]; then
      printf '%s\n' "$remote_line"
      return 0
    fi
  fi
  printf '%s\t%s\tremote_unavailable\t%s\t\t\t%s\n' \
    "$unit" "$target" "${registered_at:-$(now)}" "$owner_node"
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

running_job_conflict() {
  local requested="$1" file target state
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    [[ "$state" == running ]] || continue
    if [[ "$requested" == all-systems || "$target" == all-systems || "$target" == "$requested" ]]; then
      printf '%s\t%s\n' "$target" "$(state_value "$file" unit)"
      return 0
    fi
  done
  return 1
}

acquire_start_lock() {
  local lock_file="$JOB_STATE_DIR/.start.lock"
  exec 8>"$lock_file" || return 1
  flock -x 8 || { exec 8>&-; return 1; }
}

job_unit_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-active --quiet "$1" 2>/dev/null
}

send_update_notification() {
  local status_file="${1:-$STATUS_MODEL_FILE}"
  [[ -f "$STATUS_MODEL_SCRIPT" && -f "$status_file" ]] || return 0
  LOCAL_FILES=$(dirname -- "$status_file") \
    STATUS_MODEL_FILE="$status_file" \
    bash -c 'source "$1" && STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$2" "$3"' \
      _ "$STATUS_MODEL_SCRIPT" "$status_file" "$UPDATE_CONFIG_FILE" || true
}

validate_status_target() {
  local status_file="$1" target="$2"
  [[ -f "$STATUS_MODEL_SCRIPT" ]] || return 87
  STATUS_MODEL_FILE="$status_file" STATUS_MODEL_RECORD_FILE="${status_file}.records.$$" \
    bash -c 'source "$1" && STATUS_MODEL_VALIDATE_TARGET_FILE "$2" "$3"' \
      _ "$STATUS_MODEL_SCRIPT" "$status_file" "$target"
}

# Keep only terminal job history.  This function is deliberately best-effort:
# retention must never change the result of the job that just completed.
cleanup_completed_jobs() {
  local retention="${MAX_COMPLETED_JOBS:-50}" file unit state started epoch index_file total remove_count
  [[ "$retention" =~ ^[0-9]+$ ]] || retention=50
  index_file=$(mktemp "$JOB_STATE_DIR/.retention.XXXXXX" 2>/dev/null) || return 0
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    state=$(state_value "$file" state)
    case "$state" in
      completed|failed|interrupted) ;;
      *) continue ;;
    esac
    unit=$(state_value "$file" unit)
    job_unit_active "$unit" && continue
    started=$(state_value "$file" started_at)
    epoch=$(date -u -d "$started" +%s 2>/dev/null || true)
    [[ "$epoch" =~ ^[0-9]+$ ]] || epoch=$(stat -c '%Y' "$file" 2>/dev/null || printf '0')
    printf '%020s\t%s\n' "$epoch" "$file" >> "$index_file" || true
  done
  total=$(wc -l < "$index_file" 2>/dev/null || printf '0')
  remove_count=$((total - retention))
  if (( remove_count > 0 )); then
    sort -n -k1,1 "$index_file" | head -n "$remove_count" |
      while IFS=$'\t' read -r _ file; do
        [[ -n "$file" && -f "$file" ]] || continue
        unit=${file##*/}; unit=${unit%.state}
        rm -f -- "$file" "$(remote_ref_file "$unit")" 2>/dev/null || true
      done
  fi
  rm -f -- "$index_file" 2>/dev/null || true
  return 0
}

start_job() {
  local update_script="$1" target="$2" unit timestamp
  local conflict conflict_target conflict_unit
  local -a systemd_env=("--setenv=UU_JOB_STATE_DIR=$JOB_STATE_DIR")
  [[ -x "$update_script" ]] || { printf 'Update script is not executable: %s\n' "$update_script" >&2; return 1; }
  valid_target "$target" || { printf 'Unsupported target: %s\n' "$target" >&2; return 2; }
  command -v systemd-run >/dev/null 2>&1 || { printf 'systemd-run is required to start update jobs.\n' >&2; return 5; }
  [[ "$EUID" -eq 0 ]] || { printf 'Starting update jobs requires root.\n' >&2; return 2; }
  ensure_state_dir || { printf 'Cannot prepare job state directory: %s\n' "$JOB_STATE_DIR" >&2; return 1; }
  acquire_start_lock || { printf 'Could not acquire the job start lock.\n' >&2; return 1; }
  if conflict=$(running_job_conflict "$target"); then
    IFS=$'\t' read -r conflict_target conflict_unit <<< "$conflict"
    printf 'A job is already running for target %s (job: %s).\n' "$conflict_target" "$conflict_unit" >&2
    return 3
  fi
  systemd_env+=("--setenv=UU_DEFER_UPDATE_MAIL=true")
  if [[ "${UU_DEFER_NOTIFICATION:-false}" == true ]]; then
    systemd_env+=("--setenv=UU_DEFER_NOTIFICATION=true")
  fi
  if [[ "${UU_EXTERNAL_BACKUP_OVERRIDE:-false}" == true ]]; then
    systemd_env+=("--setenv=UU_EXTERNAL_BACKUP_OVERRIDE=true")
  fi
  if [[ "${UU_UPDATE_SCOPE:-}" == host ]]; then
    systemd_env+=("--setenv=UU_UPDATE_SCOPE=host")
  fi
  [[ -n "${UU_LOCAL_FILES:-}" ]] && systemd_env+=("--setenv=UU_LOCAL_FILES=$UU_LOCAL_FILES")
  [[ -n "${UU_REMOTE_WORK_DIR:-}" ]] && systemd_env+=("--setenv=UU_REMOTE_WORK_DIR=$UU_REMOTE_WORK_DIR")
  [[ "$target" =~ ^[0-9]+$ ]] && systemd_env+=("--setenv=UU_POST_UPDATE_STATUS_CAPTURE=true")
  prepare_systemd_log_filters

  timestamp=$(date -u '+%Y%m%d-%H%M%S-%N')
  unit="${JOB_PREFIX}$(safe_unit_target "$target")-$timestamp-$BASHPID"
  write_state "$unit" "$target" running "$(now)" '' '' || return 1
  if ! systemd-run --no-block --unit="$unit" --description="Ultimate Updater update for $target" \
    "${systemd_env[@]}" \
    "${SYSTEMD_LOG_FILTER_ARGS[@]}" \
    --property=Type=oneshot --property=StandardOutput=journal \
    --property=StandardError=journal "$RUNNER_PATH" run "$unit" "$target" "$update_script"; then
    write_state "$unit" "$target" failed "$(state_value "$(state_file "$unit")" started_at)" "$(now)" 1 "systemd-run failed" || true
    return 1
  fi
  printf 'Update job started\nTarget: %s\nJob: %s\nStatus: ultimate-updater status\nLogs: journalctl -u %s\n' \
    "$target" "$unit" "$unit"
}

start_global_job() {
  local update_script="$1" unit timestamp target=all-systems
  local -a systemd_env=("--setenv=UU_JOB_STATE_DIR=$JOB_STATE_DIR")
  [[ -x "$update_script" ]] || { printf 'Update script is not executable: %s\n' "$update_script" >&2; return 1; }
  valid_global_target "$target" || return 2
  command -v systemd-run >/dev/null 2>&1 || { printf 'systemd-run is required to start update jobs.\n' >&2; return 5; }
  [[ "$EUID" -eq 0 ]] || { printf 'Starting update jobs requires root.\n' >&2; return 2; }
  ensure_state_dir || { printf 'Cannot prepare job state directory: %s\n' "$JOB_STATE_DIR" >&2; return 1; }
  acquire_start_lock || { printf 'Could not acquire the job start lock.\n' >&2; return 1; }
  if running_job_conflict "$target" >/dev/null; then
    printf 'A job is already running; the full update was not started.\n' >&2
    return 3
  fi
  systemd_env+=("--setenv=UU_DEFER_UPDATE_MAIL=true")
  if [[ "${UU_DEFER_NOTIFICATION:-false}" == true ]]; then
    systemd_env+=("--setenv=UU_DEFER_NOTIFICATION=true")
  fi
  timestamp=$(date -u '+%Y%m%d-%H%M%S-%N')
  unit="${JOB_PREFIX}all-systems-$timestamp-$BASHPID"
  prepare_systemd_log_filters
  write_state "$unit" "$target" running "$(now)" '' '' || return 1
  if ! systemd-run --no-block --unit="$unit" --description="Ultimate Updater update for all systems" \
    "${systemd_env[@]}" \
    "${SYSTEMD_LOG_FILTER_ARGS[@]}" \
    --property=Type=oneshot --property=StandardOutput=journal \
    --property=StandardError=journal "$RUNNER_PATH" run-global "$unit" "$update_script"; then
    write_state "$unit" "$target" failed "$(state_value "$(state_file "$unit")" started_at)" "$(now)" 1 "systemd-run failed" || true
    return 1
  fi
  printf 'Update job started\nTarget: %s\nJob: %s\nStatus: ultimate-updater status\nLogs: journalctl -u %s\n' \
    "$target" "$unit" "$unit"
}

run_job() {
  local unit="$1" target="$2" update_script="$3" file started exit_code lock_file
  local post_check_rc=0 post_check_message="" captured_status_file captured_status_rc
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
  UU_DEFER_UPDATE_MAIL=true "$update_script" "$target" </dev/null
  exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    captured_status_file="${UU_REMOTE_WORK_DIR:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/temp}/post-update-status.rc"
    if [[ "$target" =~ ^[0-9]+$ && -f "$captured_status_file" ]]; then
      captured_status_rc=$(cat "$captured_status_file" 2>/dev/null || printf '1')
      [[ "$captured_status_rc" =~ ^[0-9]+$ ]] || captured_status_rc=1
      post_check_rc="$captured_status_rc"
      post_check_message="post-update target status captured before lifecycle restore rc=$post_check_rc"
      if [[ "$post_check_rc" -eq 0 ]]; then
        printf 'Post-update status captured before lifecycle restore for %s.\n' "$target"
      else
        if [[ "$post_check_rc" -eq 89 ]]; then
          post_check_message="post-update status capture failed for $target: POST_UPDATE_CAPTURE_NOT_CHECKED (exit code $post_check_rc)"
          printf 'Post-update status capture failed for %s: POST_UPDATE_CAPTURE_NOT_CHECKED (exit code %s).\n' \
            "$target" "$post_check_rc" >&2
        else
          post_check_message="post-update status capture failed for $target (exit code $post_check_rc)"
          printf 'Post-update status capture failed for %s (exit code %s).\n' \
            "$target" "$post_check_rc" >&2
        fi
      fi
    elif [[ "$target" =~ ^[0-9]+$ ]]; then
      # Guest updates capture status while a temporarily started guest is
      # still reachable. Never fall back to a normal check here: that check
      # would apply CHECK_STOPPED_* after restore and start the guest again.
      post_check_rc=127
      post_check_message="post-update target status capture missing; no second guest lifecycle started"
      printf 'Post-update status capture missing for %s; no second guest lifecycle started.\n' "$target" >&2
    elif [[ "${UU_UPDATE_SCOPE:-}" == host || "$target" == host ]]; then
      if [[ -x "$CHECK_SCRIPT" ]]; then
        UU_DEFER_NOTIFICATION=true UU_CHECK_SCOPE=host STATUS_MODEL_PARTIAL=true \
          "$CHECK_SCRIPT" host </dev/null || post_check_rc=$?
      else
        post_check_rc=127
      fi
      post_check_message="post-update host status refresh rc=$post_check_rc"
    elif [[ -x "$CHECK_CLI" ]]; then
      UU_CHECK_JOB_EXECUTION=true UU_DEFER_NOTIFICATION=true "$CHECK_CLI" check "$target" </dev/null || post_check_rc=$?
      post_check_message="post-update target status refresh rc=$post_check_rc"
    else
      post_check_rc=127
      post_check_message="post-update target status refresh rc=127 (CLI unavailable)"
    fi
    if [[ "$post_check_rc" -ne 0 ]]; then
      printf 'Post-update status refresh failed (exit code %s); update result remains successful.\n' "$post_check_rc" >&2
    else
      printf 'Post-update status refresh completed successfully.\n'
    fi
    send_update_notification "$STATUS_MODEL_FILE"
  else
    send_update_notification "$STATUS_MODEL_FILE"
  fi
  if [[ "$exit_code" -eq 0 ]]; then
    write_state "$unit" "$target" completed "$started" "$(now)" "$exit_code" "$post_check_message" || return 1
  else
    write_state "$unit" "$target" failed "$started" "$(now)" "$exit_code" || return 1
  fi
  if [[ -n "${UU_REMOTE_WORK_DIR:-}" && ( ! "$target" =~ ^[0-9]+$ || ! -f "$UU_REMOTE_WORK_DIR/post-update-status.rc" ) ]]; then
    rm -rf -- "$UU_REMOTE_WORK_DIR"
  fi
  return "$exit_code"
}

run_global_job() {
  local unit="$1" update_script="$2" target=all-systems file started exit_code lock_file
  local post_check_rc=0 post_check_message=""
  valid_unit "$unit" || return 2
  valid_global_target "$target" || return 2
  file=$(state_file "$unit")
  started=$(state_value "$file" started_at)
  command -v flock >/dev/null 2>&1 || {
    write_state "$unit" "$target" failed "$started" "$(now)" 5 "flock is unavailable"
    return 5
  }
  lock_file="$JOB_STATE_DIR/$target.lock"
  exec 9>"$lock_file" || {
    write_state "$unit" "$target" failed "$started" "$(now)" 1 "could not open global target lock"
    return 1
  }
  if ! flock -n 9; then
    write_state "$unit" "$target" failed "$started" "$(now)" 75 "another global update is running"
    return 75
  fi
  UU_DEFER_UPDATE_MAIL=true "$update_script"
  exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    printf 'Post-update status refresh started for all systems.\n'
    if [[ -x "$CHECK_CLI" ]]; then
      UU_DEFER_NOTIFICATION=true "$CHECK_CLI" check </dev/null || post_check_rc=$?
      post_check_message="post-update full status refresh rc=$post_check_rc"
    else
      post_check_rc=127
      post_check_message="post-update full status refresh rc=127 (CLI unavailable)"
    fi
    if [[ "$post_check_rc" -ne 0 ]]; then
      printf 'Post-update status refresh failed (exit code %s); update result remains successful.\n' "$post_check_rc" >&2
    else
      printf 'Post-update status refresh completed successfully.\n'
    fi
    send_update_notification "$STATUS_MODEL_FILE"
  else
    send_update_notification "$STATUS_MODEL_FILE"
  fi
  if [[ "$exit_code" -eq 0 ]]; then
    write_state "$unit" "$target" completed "$started" "$(now)" "$exit_code" "$post_check_message" || return 1
  else
    write_state "$unit" "$target" failed "$started" "$(now)" "$exit_code" || return 1
  fi
  return "$exit_code"
}

start_check_job() {
  local target="$1" cli="$2" mode="$3" unit timestamp
  local -a systemd_env=("--setenv=UU_JOB_STATE_DIR=$JOB_STATE_DIR" "--setenv=UU_JOB_TYPE=check")
  [[ -x "$cli" ]] || { printf 'CLI is not executable: %s\n' "$cli" >&2; return 1; }
  valid_target "$target" || { printf 'Unsupported check target: %s\n' "$target" >&2; return 2; }
  [[ "$mode" == target || "$mode" == node || "$mode" == all ]] || return 2
  command -v systemd-run >/dev/null 2>&1 || { printf 'systemd-run is required to start check jobs.\n' >&2; return 5; }
  [[ "$EUID" -eq 0 ]] || { printf 'Starting check jobs requires root.\n' >&2; return 2; }
  ensure_state_dir || return 1
  acquire_start_lock || { printf 'Could not acquire the job start lock.\n' >&2; return 1; }
  if running_job_conflict "$target" >/dev/null; then
    printf 'A job is already running for target %s.\n' "$target" >&2
    return 3
  fi
  timestamp=$(date -u '+%Y%m%d-%H%M%S-%N')
  unit="${CHECK_PREFIX}$(safe_unit_target "$target")-$timestamp-$BASHPID"
  [[ -n "${UU_JOB_SOURCE:-}" ]] && systemd_env+=("--setenv=UU_JOB_SOURCE=$UU_JOB_SOURCE")
  prepare_systemd_log_filters
  UU_JOB_TYPE=check write_state "$unit" "$target" running "$(now)" '' '' || return 1
  if ! systemd-run --no-block --unit="$unit" --description="Ultimate Updater check for $target" \
    "${systemd_env[@]}" "${SYSTEMD_LOG_FILTER_ARGS[@]}" --property=Type=oneshot --property=StandardOutput=journal \
    --property=StandardError=journal "$RUNNER_PATH" run-check "$unit" "$target" "$cli" "$mode"; then
    UU_JOB_TYPE=check write_state "$unit" "$target" failed "$(state_value "$(state_file "$unit")" started_at)" "$(now)" 1 "systemd-run failed" || true
    return 1
  fi
  printf 'Check job started\nTarget: %s\nJob: %s\nStatus: ultimate-updater status\nLogs: journalctl -u %s\n' \
    "$target" "$unit" "$unit"
}

start_selfupdate_job() {
  local update_script="$1" branch="$2" unit timestamp target=selfupdate
  local -a systemd_env=("--setenv=UU_JOB_STATE_DIR=$JOB_STATE_DIR" "--setenv=UU_JOB_TYPE=selfupdate" "--setenv=UU_JOB_SOURCE=web-selfupdate")
  [[ -x "$update_script" ]] || { printf 'Update script is not executable: %s\n' "$update_script" >&2; return 1; }
  [[ "$branch" == master || "$branch" == beta || "$branch" == develop ]] || { printf 'Unsupported update branch: %s\n' "$branch" >&2; return 2; }
  command -v systemd-run >/dev/null 2>&1 || { printf 'systemd-run is required to start self-update jobs.\n' >&2; return 5; }
  [[ "$EUID" -eq 0 ]] || { printf 'Starting self-update jobs requires root.\n' >&2; return 2; }
  ensure_state_dir || return 1
  acquire_start_lock || { printf 'Could not acquire the job start lock.\n' >&2; return 1; }
  if running_job_conflict "$target" >/dev/null; then
    printf 'A self-update job is already running.\n' >&2
    return 3
  fi
  timestamp=$(date -u '+%Y%m%d-%H%M%S-%N')
  unit="${JOB_PREFIX}selfupdate-$timestamp-$BASHPID"
  prepare_systemd_log_filters
  UU_JOB_TYPE=selfupdate UU_JOB_SOURCE=web-selfupdate write_state "$unit" "$target" running "$(now)" '' '' || return 1
  if ! systemd-run --no-block --unit="$unit" --description="Ultimate Updater self-update ($branch)" \
    "${systemd_env[@]}" "${SYSTEMD_LOG_FILTER_ARGS[@]}" --property=Type=oneshot --property=StandardOutput=journal \
    --property=StandardError=journal "$RUNNER_PATH" run-selfupdate "$unit" "$branch" "$update_script"; then
    UU_JOB_TYPE=selfupdate UU_JOB_SOURCE=web-selfupdate write_state "$unit" "$target" failed "$(state_value "$(state_file "$unit")" started_at)" "$(now)" 1 "systemd-run failed" || true
    return 1
  fi
  printf 'Self-update job started\nBranch: %s\nJob: %s\nLogs: journalctl -u %s\n' "$branch" "$unit" "$unit"
}

run_selfupdate_job() {
  local unit="$1" branch="$2" update_script="$3" target=selfupdate file started exit_code lock_file
  valid_unit "$unit" || return 2
  [[ "$branch" == master || "$branch" == beta || "$branch" == develop ]] || return 2
  [[ -x "$update_script" ]] || return 1
  file=$(state_file "$unit")
  started=$(state_value "$file" started_at)
  lock_file="$JOB_STATE_DIR/selfupdate.lock"
  exec 9>"$lock_file" || { UU_JOB_TYPE=selfupdate write_state "$unit" "$target" failed "$started" "$(now)" 1 "could not open self-update lock"; return 1; }
  if ! flock -n 9; then
    UU_JOB_TYPE=selfupdate write_state "$unit" "$target" failed "$started" "$(now)" 75 "another self-update is running"
    return 75
  fi
  "$update_script" "$branch" -up </dev/null
  exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    UU_JOB_TYPE=selfupdate UU_JOB_SOURCE=web-selfupdate write_state "$unit" "$target" completed "$started" "$(now)" "$exit_code" || return 1
  else
    UU_JOB_TYPE=selfupdate UU_JOB_SOURCE=web-selfupdate write_state "$unit" "$target" failed "$started" "$(now)" "$exit_code" || return 1
  fi
  return "$exit_code"
}

run_check_job() {
  local unit="$1" target="$2" cli="$3" mode="$4" file started exit_code lock_file
  valid_unit "$unit" || return 2
  valid_target "$target" || return 2
  [[ -x "$cli" ]] || return 1
  file=$(state_file "$unit")
  started=$(state_value "$file" started_at)
  lock_file="$JOB_STATE_DIR/$target.lock"
  exec 9>"$lock_file" || { UU_JOB_TYPE=check write_state "$unit" "$target" failed "$started" "$(now)" 1 "could not open target lock"; return 1; }
  if ! flock -n 9; then
    UU_JOB_TYPE=check write_state "$unit" "$target" failed "$started" "$(now)" 75 "target already locked"
    return 75
  fi
  case "$mode" in
    target) UU_CHECK_JOB_EXECUTION=true "$cli" check "$target" </dev/null ;;
    node) UU_CHECK_JOB_EXECUTION=true "$cli" check-node "$target" </dev/null ;;
    all) UU_CHECK_JOB_EXECUTION=true "$cli" check </dev/null ;;
  esac
  exit_code=$?
  if [[ "$exit_code" -eq 0 ]]; then
    UU_JOB_TYPE=check write_state "$unit" "$target" completed "$started" "$(now)" "$exit_code" || return 1
  else
    UU_JOB_TYPE=check write_state "$unit" "$target" failed "$started" "$(now)" "$exit_code" || return 1
  fi
  return "$exit_code"
}

refresh_running_jobs() {
  local file unit target state active_state load_state started age_seconds type show_rc systemd_details
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
      show_rc=0
      systemd_details=$(systemctl show "$unit" -p ActiveState -p LoadState 2>/dev/null) || show_rc=$?
      while IFS= read -r line; do
        case "$line" in
          ActiveState=*) active_state=${line#ActiveState=} ;;
          LoadState=*) load_state=${line#LoadState=} ;;
        esac
      done <<< "$systemd_details"
      case "$active_state" in
        active|activating|deactivating) ;;
        *)
          if (( show_rc == 0 )) && [[ -n "$load_state" && "$load_state" != loaded ]]; then
            started=$(state_value "$file" started_at)
            age_seconds=$(( $(date -u +%s) - $(date -u -d "$started" +%s 2>/dev/null || date -u +%s) ))
            if (( age_seconds >= 30 )); then
              type=$(state_value "$file" type)
              write_state "$unit" "$target" interrupted "$started" "$(now)" '' "unit no longer active" "${type:-update}" || true
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
  cleanup_completed_jobs || true
  local file unit target state started finished exit_code owner_node owner_host port
  shopt -s nullglob
  for file in "$JOB_STATE_DIR"/*.state; do
    unit=$(state_value "$file" unit)
    target=$(state_value "$file" target)
    state=$(state_value "$file" state)
    started=$(state_value "$file" started_at)
    finished=$(state_value "$file" finished_at)
    exit_code=$(state_value "$file" exit_code)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\n' "$unit" "$target" "$state" "$started" "$finished" "$exit_code" "$(state_value "$file" type)" "$(state_value "$file" source)"
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
    if [[ "$remote_status" == completed || "$remote_status" == failed || "$remote_status" == interrupted ]]; then
      refresh_remote_target_status "$unit" "$owner_node" "$remote_target"
    fi
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

remote_log_full() {
  local unit="$1" ref_line target owner_node owner_host port remote_command
  ref_line=$(remote_ref_line "$unit") || { printf 'Remote job reference not found: %s\n' "$unit" >&2; return 1; }
  IFS=$'\t' read -r unit target owner_node owner_host port <<< "$ref_line"
  printf -v remote_command 'journalctl -u %q --no-pager -o cat' "$unit"
  ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$owner_host" "$remote_command"
}

case "${1:-}" in
  start)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start_job "$2" "$3"
    ;;
  start-global)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    start_global_job "$2"
    ;;
  start-check)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    start_check_job "$2" "$3" "$4"
    ;;
  start-selfupdate)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    start_selfupdate_job "$2" "$3"
    ;;
  run)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    run_job "$2" "$3" "$4"
    ;;
  run-global)
    [[ $# -eq 3 ]] || { usage >&2; exit 2; }
    run_global_job "$2" "$3"
    ;;
  run-check)
    [[ $# -eq 5 ]] || { usage >&2; exit 2; }
    run_check_job "$2" "$3" "$4" "$5"
    ;;
  run-selfupdate)
    [[ $# -eq 4 ]] || { usage >&2; exit 2; }
    run_selfupdate_job "$2" "$3" "$4"
    ;;
  list)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    list_jobs
    ;;
  record-remote)
    [[ $# -eq 6 || $# -eq 7 ]] || { usage >&2; exit 2; }
    write_remote_ref "$2" "$3" "$4" "$5" "$6" "${7:-}"
    ;;
  remote-log)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    remote_log "$2"
    ;;
  remote-log-full)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    remote_log_full "$2"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
