#!/bin/bash
# shellcheck disable=SC2002,SC2015,SC2016,SC2086,SC2209,SC2317

##########
# Update #
##########

# Legacy bootstrap compatibility mirror.  Pre-metadata clients discover the
# product version by parsing this literal line from update.sh.  Runtime code
# uses product-metadata.sh as the canonical source and tests must keep these
# values aligned.
VERSION="5.2"

# A protection failure must make the overall update job fail, even when the
# configured continue-on-error mode allows other guests to be processed.
SAFETY_FAILURE=false
# Continue-on-error keeps processing later targets, but real target failures
# must still produce a non-zero final update result.
UPDATE_FAILURE=false
UPDATE_WARNING=false
UPDATE_WARNING_RC=10
UPDATE_RESULT_RECORDED=false
UPDATE_RESULT_TARGET=""
SINGLE_TARGET_EXECUTED=false
TARGET_SELECTION_RUNTIME_ERROR=false
# Informational commands share the normal EXIT trap so that their cleanup and
# exit-code handling remain centralized, but they are not update runs and must
# never emit an update summary.
NON_UPDATE_COMMAND=false
declare -a PACKAGE_MUTATION_TARGETS=()
declare -A PACKAGE_MUTATION_KEYS=()
declare -A PACKAGE_MUTATION_OPERATIONS=()
declare -A UPDATE_PENDING_BEFORE=()
declare -A DPKG_REPAIR_CHECKED=()

# Variable / Function
LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"
PRODUCT_METADATA_FILE="${UU_PRODUCT_METADATA_FILE:-$LOCAL_FILES/product-metadata.sh}"
if [[ ! -f "$PRODUCT_METADATA_FILE" ]]; then
  PRODUCT_METADATA_FILE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/product-metadata.sh"
fi
if [[ -f "$PRODUCT_METADATA_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$PRODUCT_METADATA_FILE"
fi
PRODUCT_VERSION="${PRODUCT_VERSION:-5.2}"
BETA_VERSION="${BETA_VERSION:-}"
VERSION="$PRODUCT_VERSION"
TEMP_FOLDER="/root/Ultimate-Updater-Temp"
TEMP_STATE_DIR="${UU_TEMP_STATE_DIR:-$LOCAL_FILES/temp}"
UPDATE_RUN_STARTED_AT="${UU_UPDATE_RUN_STARTED_AT:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
CONFIG_FILE="$LOCAL_FILES/update.conf"
CHECK_SCRIPT="${UU_CHECK_SCRIPT:-$LOCAL_FILES/check-updates.sh}"
USER_SCRIPTS="${USER_SCRIPTS:-$LOCAL_FILES/scripts.d}"
TARGET_RUNTIME_FILE="${TARGET_RUNTIME_FILE:-$LOCAL_FILES/target-runtime.sh}"
if [[ -f "$TARGET_RUNTIME_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$TARGET_RUNTIME_FILE"
else
  # These indirect transport calls are used by the legacy-compatible paths
  # below when an older installation has no shared runtime helper yet.
  # shellcheck disable=SC2317,SC2329
  RUN_LOCAL_COMMAND() { "$@"; }
  RUN_PCT_COMMAND() { local target_id="$1"; shift; pct exec "$target_id" -- "$@"; }
  RUN_SSH_COMMAND() { local host="$1" port="$2" user="$3"; shift 3; ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "$port" "$user@$host" "$@"; }
  RUN_PROXMOX_COMMAND() { if [[ "${DEBUG:-false}" == true ]]; then "$@"; else "$@" >/dev/null 2>&1; fi; }
  RUN_PROXMOX_CAPTURE() { local rc; PROXMOX_CAPTURE_OUTPUT=$("$@" 2>&1); rc=$?; [[ "${DEBUG:-false}" == true && -n "$PROXMOX_CAPTURE_OUTPUT" ]] && printf '%s\n' "$PROXMOX_CAPTURE_OUTPUT"; return "$rc"; }
fi

# Execute one mutating step and retain its original result without running it
# again merely to obtain diagnostics.  Interactive runs keep native terminal
# fds; headless runs capture and replay combined output for the job log.
RUN_UPDATE_COMMAND() {
  local rc
  UPDATE_STEP_OUTPUT=""
  if EFFECTIVE_HEADLESS; then
    UPDATE_STEP_OUTPUT=$("$@" 2>&1)
    rc=$?
    [[ -n "$UPDATE_STEP_OUTPUT" ]] && printf '%s\n' "$UPDATE_STEP_OUTPUT"
  else
    "$@"
    rc=$?
    UPDATE_STEP_OUTPUT="The command output was streamed directly above."
  fi
  return "$rc"
}

# Capture the package count before a mutating path or its post-check can
# replace the target record.  A missing/invalid count remains unknown; it is
# never interpreted as zero.
CAPTURE_UPDATE_PENDING_BEFORE() {
  local target="$1" status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}" count
  [[ -n "${UPDATE_PENDING_BEFORE[$target]+set}" ]] && return 0
  # Remote workers do not receive the controller status file.  The controller
  # passes the validated pre-update observation explicitly; preserve even an
  # empty or invalid value here so the normal fail-closed writer can classify
  # it as unavailable/invalid rather than inventing a zero baseline.
  if [[ "${UU_UPDATE_PENDING_BEFORE_TARGET+x}" == x &&
    "$UU_UPDATE_PENDING_BEFORE_TARGET" == "$target" ]]; then
    UPDATE_PENDING_BEFORE["$target"]="${UU_UPDATE_PENDING_BEFORE-}"
    return 0
  fi
  if declare -F STATUS_MODEL_CAPTURE_PACKAGE_BASELINE >/dev/null 2>&1; then
    count=$(STATUS_MODEL_CAPTURE_PACKAGE_BASELINE "$status_file" "$target") || count=""
  else
    count=""
  fi
  UPDATE_PENDING_BEFORE["$target"]="$count"
}

# A stopped guest has deliberately not been package-checked by the normal
# read-only inventory.  Once the update lifecycle has passed its safety gates,
# the guest is running and reachable, so obtain a fresh package observation
# before any repair or package-manager mutation.  The observation is written
# to an isolated run directory; the authoritative status model remains
# invalidated until the normal post-update capture completes.
CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE() {
  local target="$1" kind="$2" target_node="${3:-}"
  local source_files="$LOCAL_FILES" run_dir check_rc=0 baseline check_command
  local status_file record_file generation_file diagnostics_file
  [[ -n "$target" && ( "$kind" == lxc || "$kind" == vm ) ]] || return 1
  [[ -n "$target_node" ]] ||
    target_node="${UU_API_EXPECTED_TARGET_NODE:-${CLUSTER_TARGET_NODE:-${STATUS_MODEL_NODE:-$(hostname -s 2>/dev/null || hostname)}}}"
  [[ -x "$CHECK_SCRIPT" ]] || return 1
  mkdir -p -- "$TEMP_STATE_DIR" || return 1
  run_dir=$(mktemp -d "$TEMP_STATE_DIR/update-baseline.XXXXXX") || return 1
  status_file="$run_dir/status.json"
  record_file="$run_dir/status.records"
  generation_file="$run_dir/status.generations"
  diagnostics_file="$run_dir/status.diagnostics"
  check_command=ccontainer
  [[ "$kind" == vm ]] && check_command=cvm

  # The check script writes only into LOCAL_FILES/temp and the supplied status
  # artifacts.  Keep its production helpers read-only and copy only the VM
  # profile needed to resolve the selected guest transport.
  mkdir -p -- "$run_dir/temp" "$run_dir/VMs" || {
    rm -rf -- "$run_dir"
    return 1
  }
  if [[ "$kind" == vm && -f "$source_files/VMs/$target" ]]; then
    cp -- "$source_files/VMs/$target" "$run_dir/VMs/$target" || {
      rm -rf -- "$run_dir"
      return 1
    }
  fi
  printf '%s\n' '{"schema_version":1,"generated_at":null,"targets":[]}' > "$status_file" || {
    rm -rf -- "$run_dir"
    return 1
  }

  LOCAL_FILES="$run_dir" CONFIG_FILE="$CONFIG_FILE" \
  STATUS_MODEL_SCRIPT="$STATUS_MODEL_SCRIPT" STATUS_MODEL_FILE="$status_file" \
  STATUS_MODEL_RECORD_FILE="$record_file" STATUS_MODEL_GENERATION_FILE="$generation_file" \
  STATUS_MODEL_DIAGNOSTICS_FILE="$diagnostics_file" STATUS_MODEL_NODE="$target_node" \
  TARGET_RUNTIME_FILE="${TARGET_RUNTIME_FILE:-$source_files/target-runtime.sh}" \
  CLUSTER_TARGET_FILE="${CLUSTER_TARGET_FILE:-$source_files/cluster-target.sh}" \
  INTERNAL_SSH_FILE="${INTERNAL_SSH_FILE:-$source_files/internal-ssh.sh}" \
  QGA_EXEC_SCRIPT="${QGA_EXEC_SCRIPT:-$source_files/qga-guest-exec.sh}" \
  WINDOWS_UPDATE_FILE="${WINDOWS_UPDATE_FILE:-$source_files/windows-update.sh}" \
  TAG_FILTER_FILE="$source_files/tag-filter.sh" \
  APT_COUNT_SCRIPT="${APT_COUNT_SCRIPT:-$source_files/apt-count.py}" \
  APT_COUNT_SHELL_SCRIPT="${APT_COUNT_SHELL_SCRIPT:-$source_files/apt-count.sh}" \
  RPM_COUNT_SCRIPT="${RPM_COUNT_SCRIPT:-$source_files/rpm-count.py}" \
  PACKAGE_COUNT_SCRIPT="${PACKAGE_COUNT_SCRIPT:-$source_files/package-count.sh}" \
  STATUS_MODEL_PARTIAL=true UU_EXPLICIT_TARGET_CHECK=true UU_SINGLE_TARGET_CHECK=true \
  UU_CHECK_JOB_EXECUTION=true UU_JOB_SOURCE=update-baseline UU_DEFER_NOTIFICATION=true \
  TAG_OUTPUT=false "$CHECK_SCRIPT" "$check_command" "$target" \
    >"$run_dir/check-output" 2>"$run_dir/check-error" || check_rc=$?

  if [[ "$check_rc" -ne 0 ]] || [[ ! -s "$status_file" ]] ||
    ! baseline=$(STATUS_MODEL_CAPTURE_PACKAGE_BASELINE "$status_file" "$target" "$kind" "$target_node"); then
    rm -rf -- "$run_dir"
    return 1
  fi
  if [[ ! "$baseline" =~ ^[0-9]+$ ]]; then
    rm -rf -- "$run_dir"
    return 1
  fi
  UPDATE_PENDING_BEFORE["$target"]="$baseline"
  # The controller may have handed the worker an older observation (for
  # example zero while a stopped guest was not checked).  Once the guest has
  # passed the lifecycle gates, the fresh observation is authoritative for
  # this update process and must also replace the inherited scalar handoff.
  UU_UPDATE_PENDING_BEFORE_TARGET="$target"
  UU_UPDATE_PENDING_BEFORE="$baseline"
  rm -rf -- "$run_dir"
  return 0
}

RESTORE_STOPPED_LXC() {
  local target="$1"
  RUN_PROXMOX_COMMAND pct shutdown "$target" || return 1
  [[ "$(timeout 10 pct status "$target" 2>/dev/null)" == "status: stopped" ]]
}

RESTORE_STOPPED_VM() {
  local target="$1"
  RUN_PROXMOX_COMMAND qm shutdown "$target" || return 1
  [[ "$(timeout 10 qm status "$target" 2>/dev/null)" == "status: stopped" ]]
}

# All update result writes go through this wrapper.  It keeps the old
# STATUS_MODEL_UPDATE_RESULT contract while making writer failures visible and
# marking no-op/capability paths as warnings instead of successes.
RECORD_UPDATE_RESULT() {
  local target="$1" status="$2" rc="${3:-0}" result_code="${4:-}" reboot="${5:-}" processed="${6:-}"
  local pending="${UPDATE_PENDING_BEFORE[$target]-}"
  CAPTURE_UPDATE_PENDING_BEFORE "$target"
  pending="${UPDATE_PENDING_BEFORE[$target]-}"
  if [[ "$status" == success && "$pending" == 0 ]]; then
    UPDATE_WARNING=true
  elif [[ "$status" == skipped || "$status" == unsupported ]]; then
    UPDATE_WARNING=true
  fi
  if ! declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
    UPDATE_FAILURE=true
    printf 'Update result writer is unavailable for %s; refusing a successful result.\n' "$target" >&2
    return 1
  fi
  if [[ -n "$pending" ]]; then
    STATUS_MODEL_UPDATE_RESULT "$target" "$status" "$rc" "$result_code" "$reboot" "$processed" "$pending"
  else
    STATUS_MODEL_UPDATE_RESULT "$target" "$status" "$rc" "$result_code" "$reboot" "$processed"
  fi
  local result_rc=$?
  if [[ "$result_rc" -ne 0 ]]; then
    UPDATE_FAILURE=true
    printf 'Could not record update result for %s.\n' "$target" >&2
    return "$result_rc"
  fi
  UPDATE_RESULT_RECORDED=true
  UPDATE_RESULT_TARGET="$target"
  return 0
}

# Read-only capability gate.  It may inspect Proxmox configuration and the
# last authoritative status record, but it must not contact a guest or change
# lifecycle state.  Return 21 for a known unsupported/no-op path and 1 for a
# capability read failure.
UPDATE_TARGET_CAPABILITY_PRECHECK() {
  local target="$1" kind="$2" config ostype status_file
  if [[ "$kind" == lxc ]]; then
    config=$(pct config "$target" 2>/dev/null) || return 1
    ostype=$(printf '%s\n' "$config" | awk '/^ostype/ {print tolower($2); exit}')
    [[ -n "$ostype" ]] || return 1
    case "$ostype" in
      debian|ubuntu|devuan|fedora|archlinux|alpine|centos) ;;
      *) return 21 ;;
    esac
  elif [[ "$kind" == vm ]]; then
    config=$(qm config "$target" 2>/dev/null) || return 1
    ostype=$(printf '%s\n' "$config" | awk -F': ' '$1 == "ostype" {print tolower($2); exit}')
    [[ -n "$ostype" ]] || return 1
    if [[ "$ostype" =~ ^win ]] && [[ "${WINDOWS_UPDATE_ENABLED:-false}" != true ]]; then
      return 21
    fi
    status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
    if [[ -r "$status_file" ]]; then
      if python3 - "$status_file" "$target" <<'PY'
import json
import sys

path, wanted = sys.argv[1:]
try:
    payload = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError, TypeError):
    raise SystemExit(0)
for item in payload.get("targets", []):
    if not isinstance(item, dict) or str(item.get("id")) != wanted:
        continue
    code = item.get("error", {}).get("code") if isinstance(item.get("error"), dict) else None
    if item.get("check_status") == "unsupported" or code in {
        "UNSUPPORTED_OS", "UNSUPPORTED_GUEST_OS", "NO_SUPPORTED_TRANSPORT"
    }:
        raise SystemExit(21)
raise SystemExit(0)
PY
      then :; else return 21; fi
    fi
  else
    return 1
  fi
  return 0
}

UPDATE_TARGET_CAPABILITY_GUARD() {
  local target="$1" kind="$2" capability_rc
  UPDATE_TARGET_CAPABILITY_PRECHECK "$target" "$kind"
  capability_rc=$?
  case "$capability_rc" in
    0) return 0 ;;
    21) RECORD_UPDATE_RESULT "$target" unsupported 21 || true; return 21 ;;
    *) RECORD_UPDATE_RESULT "$target" failed "$capability_rc" || true; return 1 ;;
  esac
}
CLUSTER_TARGET_FILE="${CLUSTER_TARGET_FILE:-$LOCAL_FILES/cluster-target.sh}"
if [[ -f "$CLUSTER_TARGET_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$CLUSTER_TARGET_FILE"
fi
STATUS_MODEL_SCRIPT="${UU_STATUS_MODEL_SCRIPT:-$LOCAL_FILES/status-model.sh}"
if [[ -f "$STATUS_MODEL_SCRIPT" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$STATUS_MODEL_SCRIPT"
fi

API_UPDATE_TARGET_IDENTITY_GUARD() {
  [[ "${UU_API_ACTION:-}" == update ]] || return 0
  local target="$1" kind="$2" expected_id="${UU_API_EXPECTED_TARGET_ID:-}"
  [[ -n "$expected_id" ]] || {
    printf 'API_TARGET_IDENTITY_MISMATCH: expected target identity is missing.\n' >&2
    return 46
  }
  if [[ "$kind" == host ]]; then
    [[ "$expected_id" == "host:$(hostname -s 2>/dev/null || hostname)" ||
      "$expected_id" == "host:${HOSTNAME%%.*}" ]] || return 46
    [[ "${UU_API_EXPECTED_TARGET_NODE:-}" == "${HOSTNAME%%.*}" ||
      "${UU_API_EXPECTED_TARGET_NODE:-}" == "$(hostname -s 2>/dev/null || hostname)" ]] || return 46
    return 0
  fi
  [[ "$expected_id" == "$target" || "$expected_id" == "guest:$target" ]] || return 46
  if ! declare -f cluster_target_api_identity_matches >/dev/null 2>&1; then
    printf 'API_TARGET_IDENTITY_MISMATCH: current Proxmox identity cannot be verified.\n' >&2
    return 46
  fi
  cluster_target_api_identity_matches "$target" "$kind" "${UU_API_EXPECTED_TARGET_NODE:-}" "${UU_API_EXPECTED_TARGET_LOCAL:-remote}"
}

MARK_PACKAGE_DATA_INVALIDATED() {
  local target_id="$1" target_type="${2:-}" target_node="${3:-}" operation_id="${4:-${UU_PACKAGE_MUTATION_OPERATION_ID:-}}" key
  [[ -n "$target_id" && -n "$target_type" ]] || {
    printf 'Package freshness invalidation requires a complete target identity.\n' >&2
    return 46
  }
  if [[ "$target_type" != external && -z "$target_node" ]]; then
    target_node="${UU_API_EXPECTED_TARGET_NODE:-${CLUSTER_TARGET_NODE:-${STATUS_MODEL_NODE:-$(hostname -s 2>/dev/null || hostname)}}}"
  fi
  if [[ "$target_type" == lxc || "$target_type" == vm ]]; then
    # Numeric guest IDs are not an identity by themselves.  Direct CLI,
    # WebUI, scheduler, and API update paths all need the current Proxmox
    # inventory before the status-model mutation reservation is created.
    declare -f cluster_target_resolve >/dev/null 2>&1 || {
      printf 'Package freshness invalidation rejected: Proxmox identity resolver is unavailable.\n' >&2
      return 46
    }
    { [[ -n "${UU_CLUSTER_RESOURCES_JSON:-}" ]] || command -v pvesh >/dev/null 2>&1; } || {
      printf 'Package freshness invalidation rejected: current Proxmox inventory is unavailable.\n' >&2
      return 46
    }
    cluster_target_resolve "$target_id" || {
      printf 'Package freshness invalidation rejected: target identity is unavailable for %s.\n' "$target_id" >&2
      return 46
    }
    [[ "$target_type" == lxc && "$CLUSTER_TARGET_KIND" == container ||
      "$target_type" == vm && "$CLUSTER_TARGET_KIND" == vm ]] || {
      printf 'Package freshness invalidation rejected: target type changed for %s.\n' "$target_id" >&2
      return 46
    }
    if [[ -n "${UU_API_EXPECTED_TARGET_NODE:-}" &&
      "${UU_API_EXPECTED_TARGET_NODE,,}" != "${CLUSTER_TARGET_NODE,,}" ]]; then
      printf 'Package freshness invalidation rejected: target node changed for %s.\n' "$target_id" >&2
      return 46
    fi
    if [[ "${UU_API_EXPECTED_TARGET_LOCAL:-remote}" == true ||
      "${UU_API_EXPECTED_TARGET_LOCAL:-remote}" == false ]] &&
      [[ "${UU_API_EXPECTED_TARGET_LOCAL}" != "$CLUSTER_TARGET_LOCAL" ]]; then
      printf 'Package freshness invalidation rejected: target locality changed for %s.\n' "$target_id" >&2
      return 46
    fi
    target_node="$CLUSTER_TARGET_NODE"
  fi
  key="$target_id|$target_type|$target_node"
  [[ -n "${PACKAGE_MUTATION_KEYS[$key]+set}" ]] && return 0
  declare -p PACKAGE_MUTATION_OPERATIONS >/dev/null 2>&1 || declare -gA PACKAGE_MUTATION_OPERATIONS=()
  [[ -n "$operation_id" ]] || operation_id=$(STATUS_MODEL_NEW_OPERATION_ID) || return 1
  declare -f STATUS_MODEL_INVALIDATE_PACKAGE_DATA >/dev/null 2>&1 || {
    printf 'Package freshness invalidation is unavailable; update aborted.\n' >&2
    return 1
  }
  if STATUS_MODEL_INVALIDATE_PACKAGE_DATA "$target_id" "$target_type" "$target_node" "$operation_id"; then
    PACKAGE_MUTATION_KEYS["$key"]=1
    PACKAGE_MUTATION_OPERATIONS["$key"]="$operation_id"
    PACKAGE_MUTATION_TARGETS+=("$target_id|$target_type|$target_node")
    return 0
  fi
  printf 'Package freshness for target %s (%s/%s) could not be invalidated; update aborted.\n' \
    "$target_id" "$target_type" "$target_node" >&2
  return 1
}

REQUIRE_PACKAGE_DATA_INVALIDATION() {
  declare -f MARK_PACKAGE_DATA_INVALIDATED >/dev/null 2>&1 || {
    printf 'Package freshness invalidation is unavailable; update aborted.\n' >&2
    UPDATE_FAILURE=true
    return 1
  }
  return 0
}

MARK_PACKAGE_DATA_MUTATION_COMPLETE() {
  local target_id="$1" target_type="${2:-}" target_node="${3:-}" operation_id="${4:-${UU_PACKAGE_MUTATION_OPERATION_ID:-}}"
  [[ -n "$target_id" && -n "$target_type" ]] || return 2
  if [[ "$target_type" != external && -z "$target_node" ]]; then
    target_node="${UU_API_EXPECTED_TARGET_NODE:-${CLUSTER_TARGET_NODE:-${STATUS_MODEL_NODE:-$(hostname -s 2>/dev/null || hostname)}}}"
  fi
  local key="$target_id|$target_type|$target_node"
  declare -p PACKAGE_MUTATION_OPERATIONS >/dev/null 2>&1 || declare -gA PACKAGE_MUTATION_OPERATIONS=()
  if [[ -z "$operation_id" && -n "${PACKAGE_MUTATION_OPERATIONS[$key]+set}" ]]; then
    operation_id="${PACKAGE_MUTATION_OPERATIONS[$key]}"
  fi
  declare -f STATUS_MODEL_COMPLETE_PACKAGE_MUTATION >/dev/null 2>&1 || return 1
  if STATUS_MODEL_COMPLETE_PACKAGE_MUTATION "$target_id" "$target_type" "$target_node" "$operation_id"; then
    unset 'PACKAGE_MUTATION_OPERATIONS[$key]'
    return 0
  fi
  return $?
}

# shellcheck disable=SC2329
CLEAR_PACKAGE_MUTATION_RESERVATIONS() {
  local entry target_id target_type target_node
  for entry in "${PACKAGE_MUTATION_TARGETS[@]}"; do
    IFS='|' read -r target_id target_type target_node <<< "$entry"
    MARK_PACKAGE_DATA_MUTATION_COMPLETE "$target_id" "$target_type" "$target_node" || true
  done
}

INTERNAL_SSH_FILE="${INTERNAL_SSH_FILE:-$LOCAL_FILES/internal-ssh.sh}"
if [[ -f "$INTERNAL_SSH_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$INTERNAL_SSH_FILE"
else
  INTERNAL_SSH_ARGS=()
  INTERNAL_SSH_USE_IDENTITY() { :; }
  INTERNAL_SSH_RESOLVE_NODE() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER=root; INTERNAL_SSH_PORT="${3:-22}"; }
  INTERNAL_SSH_RESOLVE_VM() { INTERNAL_SSH_HOST="$2"; INTERNAL_SSH_USER="$3"; INTERNAL_SSH_PORT="${4:-22}"; }
fi
ssh() { command ssh "${INTERNAL_SSH_ARGS[@]}" "$@"; }
scp() { command scp "${INTERNAL_SSH_ARGS[@]}" "$@"; }
WINDOWS_UPDATE_FILE="${WINDOWS_UPDATE_FILE:-$LOCAL_FILES/windows-update.sh}"
if [[ -f "$WINDOWS_UPDATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$WINDOWS_UPDATE_FILE"
fi
if [[ -f "$LOCAL_FILES/status-model.sh" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$LOCAL_FILES/status-model.sh"
fi
INSTALLED_BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
case "$INSTALLED_BRANCH" in
  master|beta|develop) ;;
  *) INSTALLED_BRANCH=master ;;
esac
BUILD_METADATA_FILE="${UU_BUILD_METADATA_FILE:-$LOCAL_FILES/build-metadata}"
INSTALLED_COMMIT=""
INSTALLED_TAG=""
INSTALLED_VERSION="$VERSION"
INSTALLED_BETA=""
if [[ -r "$BUILD_METADATA_FILE" ]]; then
  INSTALLED_VERSION=$(awk -F'"' '/^version=/ {print $2; exit}' "$BUILD_METADATA_FILE")
  INSTALLED_BETA=$(awk -F'"' '/^beta=/ {print $2; exit}' "$BUILD_METADATA_FILE")
  INSTALLED_COMMIT=$(awk -F'"' '/^commit=/ {print $2; exit}' "$BUILD_METADATA_FILE")
  INSTALLED_TAG=$(awk -F'"' '/^tag=/ {print $2; exit}' "$BUILD_METADATA_FILE")
fi
[[ "$INSTALLED_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || INSTALLED_VERSION="$VERSION"
[[ "$INSTALLED_BETA" =~ ^[0-9]+$ ]] || INSTALLED_BETA=""
[[ "$INSTALLED_COMMIT" =~ ^[0-9a-f]{40}$ ]] || INSTALLED_COMMIT="unknown"
[[ "$INSTALLED_TAG" =~ ^[A-Za-z0-9._/-]+$ ]] || INSTALLED_TAG=""
INSTALLED_BUILD_IDENTITY=$(UU_FORMAT_BUILD_IDENTITY "$INSTALLED_VERSION" "$INSTALLED_BRANCH" "$INSTALLED_BETA" "$INSTALLED_COMMIT")
# USED_BRANCH describes the installed source only. A bare -up is always the
# stable master target; beta/develop require an explicit selector.
BRANCH=master
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$INSTALLED_BRANCH"
DPKG_OPTIONS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DPKG_OPTIONS_STRING="${DPKG_OPTIONS[*]}"
HEADLESS=false
IN_HEADLESS_MODE=false
if [[ "${UU_NONINTERACTIVE:-false}" == true || "${RUN_FROM_CRON:-false}" == true ]]; then
  HEADLESS=true
fi

# A configured headless mode is the persistent policy; -s/--silent remains
# the per-invocation override.  Keep this decision in one predicate so all
# update paths use the same effective semantics.
EFFECTIVE_HEADLESS() {
  [[ "${HEADLESS:-false}" == true || "${IN_HEADLESS_MODE:-false}" == true ]]
}

APT_FRONTEND_PREFIX() {
  EFFECTIVE_HEADLESS && printf 'DEBIAN_FRONTEND=noninteractive '
}

APT_COMMAND() {
  if EFFECTIVE_HEADLESS; then
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
  else
    apt-get "$@"
  fi
}

# Optional dpkg repair is deliberately a preflight, not a generic APT error
# retry. dpkg --audit is read-only and only a non-empty successful result is
# considered proof of an interrupted package configuration. Every transport
# performs the same audit -> one repair -> audit sequence after its existing
# safety gate and before the first APT command for that target.
DPKG_REPAIR_TIMEOUT="${UU_DPKG_REPAIR_TIMEOUT:-120}"
if [[ ! "$DPKG_REPAIR_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  DPKG_REPAIR_TIMEOUT=120
elif (( DPKG_REPAIR_TIMEOUT > 600 )); then
  DPKG_REPAIR_TIMEOUT=600
fi
DPKG_REPAIR_ERROR=""

# shellcheck disable=SC2329
DPKG_REPAIR_RUN_LOCAL() {
  local action="$1"
  case "$action" in
    audit)
      timeout "$DPKG_REPAIR_TIMEOUT" dpkg --audit
      ;;
    repair)
      timeout "$DPKG_REPAIR_TIMEOUT" env DEBIAN_FRONTEND=noninteractive \
        dpkg --configure -a --force-confdef --force-confold
      ;;
    *) return 2 ;;
  esac
}

# shellcheck disable=SC2329
DPKG_REPAIR_RUN_LXC() {
  local action="$1" target="$2"
  case "$action" in
    audit)
      UU_CHECK_PCT_COMMAND_TIMEOUT="$DPKG_REPAIR_TIMEOUT" \
        RUN_PCT_COMMAND "$target" bash -c 'dpkg --audit'
      ;;
    repair)
      UU_CHECK_PCT_COMMAND_TIMEOUT="$DPKG_REPAIR_TIMEOUT" \
        RUN_PCT_COMMAND "$target" bash -c \
        'DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold'
      ;;
    *) return 2 ;;
  esac
}

# shellcheck disable=SC2329
DPKG_REPAIR_RUN_SSH() {
  local action="$1" host="$2" port="$3" user="$4"
  case "$action" in
    audit)
      UU_SSH_COMMAND_TIMEOUT="$DPKG_REPAIR_TIMEOUT" \
        RUN_SSH_COMMAND "$host" "$port" "$user" bash -c 'dpkg --audit'
      ;;
    repair)
      UU_SSH_COMMAND_TIMEOUT="$DPKG_REPAIR_TIMEOUT" \
        RUN_SSH_COMMAND "$host" "$port" "$user" bash -c \
        'DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold'
      ;;
    *) return 2 ;
  esac
}

# shellcheck disable=SC2329
DPKG_REPAIR_RUN_QGA() {
  local action="$1" target="$2"
  case "$action" in
    audit)
      RUN_QEMU_COMMAND "$target" --timeout "$DPKG_REPAIR_TIMEOUT" -- \
        bash -c 'dpkg --audit'
      ;;
    repair)
      RUN_QEMU_COMMAND "$target" --timeout "$DPKG_REPAIR_TIMEOUT" -- \
        bash -c 'DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold'
      ;;
    *) return 2 ;
  esac
}

DPKG_REPAIR_PREPARE() {
  local key="$1" label="$2" runner="$3" audit_output audit_rc
  shift 3
  DPKG_REPAIR_ERROR=""
  [[ "${APT_AUTO_REPAIR_DPKG:-false}" == true ]] || return 0
  [[ -n "${DPKG_REPAIR_CHECKED[$key]+set}" ]] && return 0
  DPKG_REPAIR_CHECKED["$key"]=true

  audit_rc=0
  audit_output=$("$runner" audit "$@" 2>&1) || audit_rc=$?
  if [[ "$audit_rc" -ne 0 ]]; then
    # An unavailable read-only probe is not proof of a broken dpkg state.
    # Leave the normal APT error handling in charge and never repair blindly.
    printf 'DPKG_REPAIR_CHECK_UNAVAILABLE: %s\n' "$label"
    return 0
  fi
  [[ -n "${audit_output//[[:space:]]/}" ]] || return 0

  printf 'DPKG_REPAIR_BEGIN: %s\n' "$label"
  if [[ "$key" == host:* ]]; then
    printf 'DPKG_REPAIR_WARNING: the Proxmox host has no configured guest snapshot/backup gate.\n'
  else
    printf 'DPKG_REPAIR_INFO: existing snapshot/backup gate completed before repair.\n'
  fi
  if ! "$runner" repair "$@"; then
    DPKG_REPAIR_ERROR="DPKG_REPAIR_FAILED"
    printf '%s: %s\n' "$DPKG_REPAIR_ERROR" "$label" >&2
    return 1
  fi

  audit_rc=0
  audit_output=$("$runner" audit "$@" 2>&1) || audit_rc=$?
  if [[ "$audit_rc" -ne 0 || -n "${audit_output//[[:space:]]/}" ]]; then
    DPKG_REPAIR_ERROR="DPKG_REPAIR_FAILED"
    printf '%s: %s (dpkg audit still reports an interrupted state)\n' \
      "$DPKG_REPAIR_ERROR" "$label" >&2
    return 1
  fi
  printf 'DPKG_REPAIR_COMPLETE: %s\n' "$label"
}

# Tag filter
# shellcheck disable=SC1091
. "$LOCAL_FILES/tag-filter.sh"
USE_INTERNAL_TARGET_SELECTION="${USE_INTERNAL_TARGET_SELECTION:-false}"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

DOWNLOAD_SHELL_FILE() {
  local url="$1" temporary headers http_code retry_after
  mkdir -p "$TEMP_FOLDER" || return 1
  temporary=$(mktemp "$TEMP_FOLDER/download.sh.XXXXXX") || return 1
  headers=$(mktemp "$TEMP_FOLDER/download.headers.XXXXXX") || { rm -f -- "$temporary"; return 1; }
  http_code=$(curl -4 -sS -fSL --retry 0 --connect-timeout 5 --max-time 120 \
    -D "$headers" -o "$temporary" -w '%{http_code}' "$url" 2>/dev/null) || {
    if [[ "$http_code" == 429 ]]; then
      retry_after=$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$headers")
      if [[ -n "$retry_after" ]]; then
        echo "GitHub temporarily rate-limited the download (Retry-After: $retry_after). Please retry later." >&2
      else
        echo "GitHub temporarily rate-limited the download. Please retry later." >&2
      fi
    else
      echo "Download failed (HTTP ${http_code:-unavailable})." >&2
    fi
    rm -f -- "$temporary" "$headers"
    return 1
  }
  if [[ ! -s "$temporary" ]] || ! [[ "$(head -n 1 "$temporary")" =~ ^#!.*(bash|sh) ]] || ! bash -n "$temporary"; then
    echo "Downloaded installer failed shell validation." >&2
    rm -f -- "$temporary" "$headers"
    return 1
  fi
  rm -f -- "$headers"
  printf '%s\n' "$temporary"
}

# Opt-in protection for externally managed Updater source distributions.
# This blocks source replacement only; package/guest updates, read-only checks,
# status queries, and uninstall remain available.
CHECK_EXTERNAL_RELEASE_PIN() {
  local pin="/etc/ultimate-updater/.source-release-pin"
  if [[ -e "$pin" || -L "$pin" ]]; then
    printf '%s\n' \
      'Externally managed Updater source is pinned; use the external verified release procedure instead.' >&2
    return 78
  fi
  return 0
}

RUN_DOWNLOADED_INSTALLER() {
  local installer_path rc command source_url
  local -a environment=()
  source_url=$1
  shift
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    environment+=("$1")
    shift
  done
  command=${1:-}
  shift || true
  if [[ "$command" != uninstall ]]; then
    CHECK_EXTERNAL_RELEASE_PIN || return $?
  fi
  installer_path=$(DOWNLOAD_SHELL_FILE "$source_url") || return 1
  env "${environment[@]}" bash "$installer_path" "$command" "$@"
  rc=$?
  rm -f -- "$installer_path"
  return "$rc"
}



SHOULD_CLEAR_UPDATE_HEADER() {
  [[ -t 0 && -e /dev/tty && -w /dev/tty && "${TERM:-}" != "" && "${TERM:-}" != dumb ]] || return 1
  [[ "${UU_MANAGED_OUTPUT:-false}" != true ]] || return 1
  [[ "${UU_NONINTERACTIVE:-false}" != true && "${UU_JOB_SOURCE:-}" != scheduler ]]
}

CLEAR_UPDATE_HEADER() {
  SHOULD_CLEAR_UPDATE_HEADER || return 0
  clear > /dev/tty 2>/dev/null || true
}

# Header
HEADER_INFO () {
  CLEAR_UPDATE_HEADER
  echo -e "\n \
    https://github.com/BassT23/Proxmox\n"
  cat <<'EOF'
 The __  ______  _                 __
    / / / / / /_(_)___ ___  ____ _/ /____
   / / / / / __/ / __ `__ \/ __ `/ __/ _ \
  / /_/ / / /_/ / / / / / / /_/ / /_/  __/
  \____/_/\__/_/_/ /_/ /_/\____/\__/\___/
     __  __          __      __
    / / / /___  ____/ /___ _/ /____  ____
   / / / / __ \/ __  / __ `/ __/ _ \/ __/
  / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
  \____/ ____/\____/\____/\__/\___/_/
      /_/                for Proxmox VE
EOF
  if [[ "$INFO" != false ]]; then
    echo -e "\n \
          ***  Mode: $MODE***"
    if EFFECTIVE_HEADLESS; then
      echo -e "           ***    Headless    ***"
    else
      echo -e "           ***   Interactive  ***"
    fi
  fi
  CHECK_ROOT
  CHECK_INTERNET
  if [[ "$INFO" != false && "$CHECK_VERSION" == true ]]; then VERSION_CHECK; else echo; fi
  # Print tag selection summary captured during config parse
  [[ "${TAG_LOG:-}" == "true" ]] && type print_tag_log >/dev/null 2>&1 && { print_tag_log; echo; } || true
}

# Check root
CHECK_ROOT () {
  if [[ "$RICM" != true && "$EUID" -ne 0 ]]; then
      echo -e "\n${RD:-} ⚠ --- Please run this as root --- ⚠${CL:-}\n"
      exit 2
  fi
}

START_INITIAL_INVENTORY () {
  local job_runner="$LOCAL_FILES/job-runner.sh" cli="$LOCAL_FILES/ultimate-updater" output
  [[ "$EUID" -eq 0 ]] || { echo -e "${RD:-}❌ Initial inventory requires root.${CL:-}" >&2; return 2; }
  [[ -x "$job_runner" && -x "$cli" ]] || {
    echo -e "${RD:-}❌ Initial inventory infrastructure is unavailable.${CL:-}" >&2
    return 1
  }
  if ! output=$(UU_JOB_SOURCE=initial-inventory timeout 15 "$job_runner" start-check all-systems "$cli" all 2>&1); then
    printf '%s\n' "$output" >&2
    return 1
  fi
  INITIAL_INVENTORY_CLI=true
  echo 'Initial inventory started.'
  printf '%s\n' "$output"
}

# Check internet status
CHECK_INTERNET () {
  local attempt delay
  for attempt in 1 2 3; do
    if "$CHECK_URL_EXE" -q -c1 "$CHECK_URL" &>/dev/null; then
      [[ "$attempt" -gt 1 ]] && echo -e "${GN:-}✅ Internet connection available${CL:-}"
      return 0
    fi
    if [[ "$attempt" -lt 3 ]]; then
      delay=$((attempt + 1))
      echo "Internet check failed (attempt $attempt/3), retrying..." >&2
      sleep "$delay"
    fi
  done
  echo -e "\n${OR:-} ❌ Internet check fail - Can't update without internet${CL:-}\n"
  exit 2
}

ARGUMENTS () {
  while [[ $# -gt 0 ]]; do
    local ARGUMENT="$1"
    case "$ARGUMENT" in
      [0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])
        COMMAND=true
        SINGLE_UPDATE=true
        MODE=" Single "
        ONLY=$ARGUMENT
        if declare -f cluster_target_resolve >/dev/null 2>&1 &&
          { [[ -n "${UU_CLUSTER_RESOURCES_JSON:-}" ]] || command -v pvesh >/dev/null 2>&1; }; then
          if cluster_target_resolve "$ARGUMENT"; then
            if ! API_UPDATE_TARGET_IDENTITY_GUARD "$ARGUMENT" "$CLUSTER_TARGET_KIND"; then
              printf 'API_TARGET_IDENTITY_MISMATCH: target identity changed before update execution.\n' >&2
              return 46
            fi
            if [[ "$CLUSTER_TARGET_LOCAL" == false ]]; then
              local remote_command remote_operation_id
              remote_operation_id=$(STATUS_MODEL_NEW_OPERATION_ID) || return 1
              if ! MARK_PACKAGE_DATA_INVALIDATED "$ARGUMENT" \
                "$([[ "$CLUSTER_TARGET_KIND" == container ]] && printf lxc || printf vm)" \
                "$CLUSTER_TARGET_NODE" "$remote_operation_id"; then
                printf 'Package freshness for remote target %s could not be invalidated; update aborted.\n' "$ARGUMENT" >&2
                return 1
              fi
              CAPTURE_UPDATE_PENDING_BEFORE "$ARGUMENT"
              local remote_pending_env
              printf -v remote_pending_env 'UU_UPDATE_PENDING_BEFORE_TARGET=%q UU_UPDATE_PENDING_BEFORE=%q ' \
                "$ARGUMENT" "${UPDATE_PENDING_BEFORE[$ARGUMENT]-}"
              printf -v remote_command 'exec /usr/bin/env %sUU_PACKAGE_MUTATION_OPERATION_ID=%q %q start %q %q' \
                "$remote_pending_env" "$remote_operation_id" "/etc/ultimate-updater/job-runner.sh" "/etc/ultimate-updater/update.sh" "$ARGUMENT"
              echo -e "ℹ ${OR:-} Target $ARGUMENT resolved to $CLUSTER_TARGET_NODE; starting remote update job${CL:-}\n"
              local remote_output remote_job_unit
              if ! remote_output=$(ssh -q -o BatchMode=yes -o ConnectTimeout=5 -p "${SSH_PORT:-22}" \
                "$CLUSTER_TARGET_HOST" "$remote_command"); then
                echo -e "${RD:-}❌ Could not start update job on $CLUSTER_TARGET_NODE${CL:-}" >&2
                return 6
              fi
              printf '%s\n' "$remote_output"
              remote_job_unit=$(printf '%s\n' "$remote_output" | sed -n 's/^Job:[[:space:]]*//p' | head -n 1)
              if [[ ! "$remote_job_unit" =~ ^ultimate-updater-update-[A-Za-z0-9_.-]+$ ]] ||
                ! "$LOCAL_FILES/job-runner.sh" record-remote "$remote_job_unit" "$ARGUMENT" \
                  "$CLUSTER_TARGET_NODE" "$CLUSTER_TARGET_HOST" "${SSH_PORT:-22}"; then
                echo -e "${RD:-}❌ Remote job started but could not be referenced locally${CL:-}" >&2
                return 7
              fi
              REMOTE_TARGET_DISPATCHED=true
              shift
              continue
            fi
          else
            local cluster_result=$?
            case "$cluster_result" in
              1) echo -e "${RD:-}❌ Target $ARGUMENT not found in Proxmox cluster${CL:-}" >&2 ;;
              2) echo -e "${RD:-}❌ Target ID must be numeric: $ARGUMENT${CL:-}" >&2 ;;
              4) echo -e "${RD:-}❌ Target ID $ARGUMENT is ambiguous across the cluster${CL:-}" >&2 ;;
              *) echo -e "${RD:-}❌ Could not read the Proxmox cluster inventory${CL:-}" >&2 ;;
            esac
            return "$cluster_result"
          fi
        fi
        HEADER_INFO
        if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
        echo -e "ℹ ${OR:-} Updating only LXC/VM $ARGUMENT${CL:-}\n"
        CONTAINER_UPDATE_START
        VM_UPDATE_START
        ;;
      -h|--help) NON_UPDATE_COMMAND=true; USAGE; exit 0 ;;
      -v|--version) NON_UPDATE_COMMAND=true; VERSION_CHECK; exit 0 ;;
      -s|--silent) HEADLESS=true ;;
      -c) RICM=true ;;
      -w) WELCOME_SCREEN=true ;;
      host)
        COMMAND=true
        TAG_LOG=true
        if ! API_UPDATE_TARGET_IDENTITY_GUARD host host; then
          printf 'API_TARGET_IDENTITY_MISMATCH: node identity changed before update execution.\n' >&2
          return 46
        fi
        if [[ "$RICM" != true ]]; then
          MODE="  Host  "
          HEADER_INFO
          if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
        fi
        echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
        if [[ "$WITH_HOST" == true && "${UU_INTERNAL_SKIP_HOST_TARGET:-false}" != true ]]; then
          UPDATE_HOST_ITSELF
          CHOST=""
        else
          echo -e "⏩${BL:-} Skipped host itself by the user${CL:-}\n\n"
        fi
        if [[ "${UU_UPDATE_SCOPE:-}" == host ]]; then
          echo -e "⏩${BL:-} Skipped all containers and VMs: host-only update${CL:-}\n"
        elif [[ "$WITH_LXC" == true ]]; then
          CONTAINER_UPDATE_START
        else
          echo -e "⏩${BL:-} Skipped all containers by the user${CL:-}\n"
        fi
        if [[ "${UU_UPDATE_SCOPE:-}" != host && "$WITH_VM" == true ]]; then
          VM_UPDATE_START
        elif [[ "${UU_UPDATE_SCOPE:-}" != host ]]; then
          echo -e "⏩${BL:-} Skipped all VMs by the user${CL:-}\n"
        fi
        ;;
      cluster)
        COMMAND=true
        MODE="Cluster "
        HEADER_INFO
        HOST_UPDATE_START
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        # shellcheck disable=SC2317
        exit 2
        ;;
      master|beta|develop)
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR:-}  Wrong usage! Use branch update like this:${CL:-}"
          echo -e "  update $ARGUMENT -up\n"
          exit 2
        fi
        BRANCH=$ARGUMENT
        EXPLICIT_BRANCH=true
        ;;
      -up)
        COMMAND=true
        # BRANCH is initialized to master. An explicit selector above is the
        # only way to target beta or develop.
        UPDATE
        exit $?
        ;;
      -dist-upgrade)
        INFO=false
        HEADER_INFO
        COMMAND=true
        READ_CONFIG
        CHECK_DIST=true
        CONTAINER_UPDATE_START
        exit 2
        ;;
      -check)
        local check_rc=0
        CHECK_ONLY_RUN=true
        "$LOCAL_FILES/check-updates.sh" || check_rc=$?
        exit "$check_rc"
        ;;
      inventory)
        COMMAND=true
        START_INITIAL_INVENTORY
        exit $?
        ;;
      status)
        INFO=false
        HEADER_INFO
        COMMAND=true
        STATUS
        exit 2
        ;;
      *)
        echo -e "\n${RD:-} ❌ Error: Got an unexpected argument \"$ARGUMENT\"${CL:-}";
        USAGE;
        exit 2;
        ;;
    esac
    shift
  done
}

# Usage
USAGE () {
  if ! EFFECTIVE_HEADLESS; then
    echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
    echo -e "[OPTIONS] Manages the Ultimate Updater:"
    echo -e "======================================"
    echo -e "  master               Use master branch"
    echo -e "  beta                 Use beta branch (pre-release)"
    echo -e "  develop              Use develop branch\n"
    echo -e "{COMMAND}:"
    echo -e "========="
    echo -e "  -s --silent          Silent / Headless Mode"
    echo -e "  -h --help            Show help menu"
    echo -e "  -v --version         Show The Ultimate Updater version"
    echo -e "  -dist-upgrade        Run distribution upgrade (Debian 12 -> 13)"
    echo -e "  -check               Run check-updates.sh"
    echo -e "  inventory            Start a read-only initial inventory job"
    echo -e "  -up                  Update/install the stable master branch"
    echo -e "  master -up           Explicitly install/update master"
    echo -e "  beta -up             Explicitly install/update beta"
    echo -e "  develop -up          Explicitly install/update develop"
    echo -e "  status               Show Status (Version Infos)"
    echo -e "  uninstall            Uninstall The Ultimate Updater\n"
    echo -e "  host                 Host-Mode"
    echo -e "  cluster              Cluster-Mode\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check / Update Message in Header
RUN_BRANCH_UPDATE () {
  local target_branch=$1 installer cache_buster
  CHECK_EXTERNAL_RELEASE_PIN || return $?
  cache_buster=$(date +%s)

  if ! installer=$(DOWNLOAD_SHELL_FILE "https://raw.githubusercontent.com/BassT23/Proxmox/refs/heads/$target_branch/install.sh?uu_cache=$cache_buster"); then
    echo -e "${RD:-}Unable to download the $target_branch installer.${CL:-}"
    return 1
  fi
  env UU_TARGET_BRANCH="$target_branch" bash "$installer" update
  local rc=$?
  rm -f -- "$installer"
  return "$rc"
}

SHOW_UPDATE_NOTICE () {
  local target_branch=$1 remote_version=$2 remote_commit=${3:-} remote_beta=${4:-}
  local available_identity
  available_identity=$(UU_FORMAT_BUILD_IDENTITY "$remote_version" "$target_branch" "$remote_beta" "$remote_commit")

  echo -e "${OR:-}*** A newer version is available ***${CL:-}\n\
       Installed: $INSTALLED_BUILD_IDENTITY\n       Available: $available_identity"
  if ! EFFECTIVE_HEADLESS; then
    echo -e "${OR:-}Want to update The Ultimate Updater first?${CL:-}"
    read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
    if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
      RUN_BRANCH_UPDATE "$target_branch"
    fi
    echo
  fi
}

VERSION_CHECK () {
  local candidate remote_version remote_available=false current_commit remote_beta
  local -a candidates
  local branch_for_status=${INSTALLED_BRANCH:-master}

  LOCAL_VERSION="$INSTALLED_VERSION"
  case "$branch_for_status" in
    master) candidates=(master) ;;
    beta) candidates=(master beta) ;;
    develop) candidates=(master beta develop) ;;
    *)
      echo -e "${OR:-}The configured branch '$branch_for_status' is not active; use master, beta, or develop.${CL:-}"
      echo -e "                 Ultimate Updater $INSTALLED_BUILD_IDENTITY"
      return 0
      ;;
  esac

  if [[ "$branch_for_status" == develop ]]; then
    echo -e "${OR:-}*** The Ultimate Updater is on develop branch ***${CL:-}"
  elif [[ "$branch_for_status" == beta ]]; then
    echo -e "${OR:-}*** The Ultimate Updater is on beta branch (pre-release) ***${CL:-}"
  fi
  VERSION_NOT_SHOW=false
  for candidate in "${candidates[@]}"; do
    if ! remote_version=$(FETCH_REMOTE_VERSION "$candidate" update.sh); then
      echo -e "${OR:-}Unable to read the $candidate version from GitHub.${CL:-}"
      continue
    fi
    remote_available=true
    if version_is_less "$LOCAL_VERSION" "$remote_version"; then
      SHOW_UPDATE_NOTICE "$candidate" "$remote_version"
      VERSION_NOT_SHOW=true
      break
    fi
  done
  if [[ "$VERSION_NOT_SHOW" != true && "$remote_available" == true ]]; then
    current_commit=$(FETCH_REMOTE_COMMIT "$branch_for_status" || true)
    if [[ "$branch_for_status" != master && "$current_commit" =~ ^[0-9a-f]{40}$ && "$current_commit" != "$INSTALLED_COMMIT" ]]; then
      remote_beta=$(FETCH_REMOTE_BETA "$branch_for_status" || true)
      SHOW_UPDATE_NOTICE "$branch_for_status" "$INSTALLED_VERSION" "$current_commit" "$remote_beta"
      VERSION_NOT_SHOW=true
    fi
  fi
  if [[ "$VERSION_NOT_SHOW" != true && "$remote_available" == true ]]; then
    echo -e "${GN:-}       The Ultimate Updater is UpToDate${CL:-}"
    echo -e "                 Ultimate Updater $INSTALLED_BUILD_IDENTITY"
  elif [[ "$VERSION_NOT_SHOW" != true ]]; then
    echo -e "${OR:-}       Unable to verify the remote version${CL:-}"
    echo -e "                 Ultimate Updater $INSTALLED_BUILD_IDENTITY"
  fi
}

# Update The Ultimate Updater
SAME_INSTALLED_TARGET_IDENTITY() {
  [[ "$INSTALLED_BRANCH" == "$BRANCH" ]] || return 1
  [[ "$INSTALLED_VERSION" == "$target_version" ]] || return 1
  [[ "$installed_commit" =~ ^[0-9a-f]{40}$ && "$target_commit" == "$installed_commit" ]] || return 1
  if [[ "$BRANCH" == beta ]]; then
    [[ "$target_beta" =~ ^[0-9]+$ && "$INSTALLED_BETA" == "$target_beta" ]] || return 1
  fi
  return 0
}

UPDATE () {
  SELF_UPDATE_RUN=true
  local installed_version target_version target_commit installed_commit target_beta cache_buster
  CHECK_EXTERNAL_RELEASE_PIN || return $?
  cache_buster=$(date +%s)
  installed_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh" 2>/dev/null || true)
  if ! target_version=$(FETCH_REMOTE_VERSION "$BRANCH" update.sh); then
    echo -e "${RD:-}Unable to determine the target version for branch $BRANCH; update aborted before mutation.${CL:-}" >&2
    return 2
  fi
  installed_commit=$(awk -F'"' '/^commit=/ {print $2; exit}' "$BUILD_METADATA_FILE" 2>/dev/null || true)
  target_commit=$(FETCH_REMOTE_COMMIT "$BRANCH" || true)
  target_beta=$(FETCH_REMOTE_BETA "$BRANCH" || true)
  if SAME_INSTALLED_TARGET_IDENTITY; then
    echo -e "${GN:-}       The Ultimate Updater is UpToDate${CL:-}"
    echo -e "                 Ultimate Updater $INSTALLED_BUILD_IDENTITY"
    return 0
  fi
  if version_is_less "$target_version" "$installed_version"; then
    echo -e "\n${OR:-}⚠ Downgrade notice${CL:-}\n"
    echo -e "You are currently running Ultimate Updater $installed_version."
    echo -e "The $BRANCH branch currently provides version $target_version."
    echo -e "Running this command will downgrade Ultimate Updater to version $target_version.\n"
    echo -e "The downgrade is not performed automatically. Continue with downgrade? [y/N]"
    if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
      echo -e "${RD:-}Interactive confirmation required for a downgrade; update aborted before mutation.${CL:-}" >&2
      return 2
    fi
    read -r -p "Continue with downgrade? [y/N] " downgrade_reply
    if [[ ! "$downgrade_reply" =~ ^[Yy]$ ]]; then
      echo "Downgrade cancelled by user."
      return 0
    fi
  fi
  if [[ "${EXPLICIT_BRANCH:-false}" == true && "$BRANCH" != "$INSTALLED_BRANCH" ]]; then
    PRINT_BRANCH_PROMPT
    if [[ "${UU_NONINTERACTIVE:-false}" != true && -t 0 ]]; then
      read -r -p "Type [Y/y] or [Enter] for yes - anything else will exit: " branch_reply
      if [[ "$branch_reply" =~ ^[Nn] || ( -n "$branch_reply" && ! "$branch_reply" =~ ^[Yy]$ ) ]]; then
        return 2
      fi
    fi
  fi
  if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
    RUN_DOWNLOADED_INSTALLER "https://raw.githubusercontent.com/BassT23/Proxmox/refs/heads/$BRANCH/install.sh?uu_cache=$cache_buster" \
      UU_TARGET_BRANCH="$BRANCH" UU_NONINTERACTIVE=true update
    return $?
  fi
  RUN_DOWNLOADED_INSTALLER "https://raw.githubusercontent.com/BassT23/Proxmox/refs/heads/$BRANCH/install.sh?uu_cache=$cache_buster" \
    UU_TARGET_BRANCH="$BRANCH" UU_UPGRADE_INTERACTIVE=true UU_INTERACTIVE_INSTALLER=true UU_NONINTERACTIVE=true update
  return $?
}

PRINT_BRANCH_PROMPT () {
  local branch_color=""
  case "$BRANCH" in
    beta) branch_color="$OR" ;;
    develop) branch_color="$RD" ;;
  esac
  if [[ -n "$branch_color" ]]; then
    printf 'Update to %b%s%b branch?\n' "$branch_color" "$BRANCH" "$CL"
  else
    printf 'Update to %s branch?\n' "$BRANCH"
  fi
}

# Uninstall
UNINSTALL () {
  echo -e "\n⚠ ${OR:-} Uninstall The Ultimate Updater${CL:-}\n"
  echo -e "${RD:-}Really want to remove The Ultimate Updater?${CL:-}"
  read -p "Type [Y/y] for yes - anything else will exit: " -r
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    RUN_DOWNLOADED_INSTALLER "$SERVER_URL/install.sh" uninstall
    exit 2
  else
    exit 2
  fi
}

# Get the exact commit currently served by the installed branch.  This is
# metadata for comparison only; the installer writes the installed commit.
FETCH_REMOTE_COMMIT() {
  local branch="$1"
  [[ "$branch" =~ ^(master|beta|develop)$ ]] || return 1
  curl -4 -sS --connect-timeout 5 --max-time 15 \
    "https://api.github.com/repos/BassT23/Proxmox/commits/$branch" 2>/dev/null |
    awk -F'"' '/"sha"[[:space:]]*:/ {print $4; exit}'
}

FETCH_REMOTE_BETA() {
  local branch="$1"
  [[ "$branch" =~ ^(beta|develop)$ ]] || return 1
  curl -4 -sS --connect-timeout 5 --max-time 15 \
    "https://raw.githubusercontent.com/BassT23/Proxmox/$branch/product-metadata.sh" 2>/dev/null |
    awk -F'"' '/^BETA_VERSION=/ {print $2; exit}'
}

# Get Server Versions
STATUS () {
  local branch_for_status=${INSTALLED_BRANCH:-master} component label local_file local_version remote_version remote_commit remote_beta
  local -a components=(
    "Updater|update.sh|$LOCAL_FILES/update.sh"
    "Extras|update-extras.sh|$LOCAL_FILES/update-extras.sh"
    "Config|update.conf|$LOCAL_FILES/update.conf"
  )

  if [[ "$WELCOME_SCREEN" == true ]]; then
    components+=("Welcome|welcome-screen.sh|/etc/update-motd.d/01-welcome-screen")
    components+=("Check|check-updates.sh|$LOCAL_FILES/check-updates.sh")
  fi
  if [[ "$branch_for_status" != master && "$branch_for_status" != beta && "$branch_for_status" != develop ]]; then
    echo -e "${RD:-}Unknown branch '$branch_for_status'; status cannot be retrieved.${CL:-}"
    return 1
  fi

  printf 'Ultimate Updater %s\n\n' "$INSTALLED_BUILD_IDENTITY"
  echo -e "${OR:-}  Version overview ($branch_for_status)${CL:-}\n"
  printf 'Installed product version: %s\n' "$INSTALLED_VERSION"
  printf 'Installed beta: %s\n' "${INSTALLED_BETA:-—}"
  printf 'Installed commit: %s\n' "${INSTALLED_COMMIT:-unknown}"
  remote_commit=$(FETCH_REMOTE_COMMIT "$branch_for_status" || true)
  [[ "$remote_commit" =~ ^[0-9a-f]{40}$ ]] || remote_commit="unavailable"
  remote_beta=$(FETCH_REMOTE_BETA "$branch_for_status" || true)
  printf 'Available commit: %s\n' "$remote_commit"
  printf 'Available beta: %s\n' "${remote_beta:-—}"
  printf 'Installed tag: %s\n\n' "${INSTALLED_TAG:-—}"
  printf '%-12s %-9s %-9s\n' "Component" "Local" "Server"
  printf '%-12s %-9s %-9s\n' "---------" "-----" "------"
  for component in "${components[@]}"; do
    IFS='|' read -r label component local_file <<< "$component"
    local_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$local_file" 2>/dev/null || true)
    remote_version=$(FETCH_REMOTE_VERSION "$branch_for_status" "$component" 5 || true)
    if [[ -z "$local_version" ]]; then local_version="unknown"; fi
    if [[ -z "$remote_version" ]]; then remote_version="unavailable"; fi
    if [[ "$local_version" == "$remote_version" ]]; then
      printf '%-12s %b%-9s%b %-9s\n' "$label" "${GN:-}" "$local_version" "${CL:-}" "$remote_version"
    else
      printf '%-12s %-9s %b%-9s%b\n' "$label" "$local_version" "${OR:-}" "$remote_version" "${CL:-}"
    fi
  done
  echo
}

# Read Config File
READ_CONFIG () {
  LOG_FILE=$(awk -F'"' '/^LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  ERROR_LOG_FILE=$(awk -F'"' '/^ERROR_LOG_FILE=/ {print $2}' "$CONFIG_FILE")
  CHECK_VERSION=$(awk -F'"' '/^VERSION_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL=$(awk -F'"' '/^URL_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL_EXE=$(awk -F'"' '/^EXE_FOR_INTERNET_CHECK=/ {print $2}' "$CONFIG_FILE")
  CHECK_URL_EXE="${CHECK_URL_EXE:-ping}"
  SSH_PORT=$(awk -F'"' '/^SSH_PORT=/ {print $2}' "$CONFIG_FILE")
  EXIT_ON_ERROR=$(awk -F'"' '/^EXIT_ON_ERROR=/ {print $2}' "$CONFIG_FILE")
  REBOOT_IF_NEEDED=$(awk -F'"' '/^REBOOT_IF_NEEDED=/ {print $2; exit}' "$CONFIG_FILE")
  [[ "$REBOOT_IF_NEEDED" == true ]] || REBOOT_IF_NEEDED=false
  APT_AUTO_REPAIR_DPKG=$(awk -F'"' '/^APT_AUTO_REPAIR_DPKG=/ {print $2; exit}' "$CONFIG_FILE")
  [[ "$APT_AUTO_REPAIR_DPKG" == true ]] || APT_AUTO_REPAIR_DPKG=false
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING_CONTAINER=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED_CONTAINER=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  RUNNING_VM=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$CONFIG_FILE")
  STOPPED_VM=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$CONFIG_FILE")
  FREEBSD_UPDATES=$(awk -F'"' '/^FREEBSD_UPDATES=/ {print $2}' "$CONFIG_FILE")
  WINDOWS_UPDATE_ENABLED=$(awk -F'"' '/^WINDOWS_UPDATE_ENABLED=/ {print $2}' "$CONFIG_FILE")
  WINDOWS_UPDATE_ENABLED="${WINDOWS_UPDATE_ENABLED:-false}"
  SNAPSHOT=$(awk -F'"' '/^SNAPSHOT/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT=$(awk -F'"' '/^KEEP_SNAPSHOTS=/ {print $2}' "$CONFIG_FILE")
  KEEP_SNAPSHOT="${KEEP_SNAPSHOT:-$(awk -F'"' '/^KEEP_SNAPSHOT=/ {print $2}' "$CONFIG_FILE")}"
  KEEP_SNAPSHOT="${KEEP_SNAPSHOT:-3}"
  BACKUP=$(awk -F'"' '/^BACKUP=/ {print $2}' "$CONFIG_FILE")
  BACKUP_LXC_MP=$(awk -F'"' '/^BACKUP_LXC_MP=/ {print $2}' "$CONFIG_FILE")
  BACKUP_MODE=$(awk -F'"' '/^BACKUP_MODE=/ {print $2}' "$CONFIG_FILE")
  BACKUP_STORAGE=$(awk -F'"' '/^BACKUP_STORAGE=/ {print $2}' "$CONFIG_FILE")
  BACKUP_LXC_MP="${BACKUP_LXC_MP:-true}"
  BACKUP_MODE="${BACKUP_MODE:-stop}"
  BACKUP_STORAGE="${BACKUP_STORAGE-}"
  LXC_START_DELAY=$(awk -F'"' '/^LXC_START_DELAY=/ {print $2}' "$CONFIG_FILE")
  LXC_START_DELAY="${LXC_START_DELAY:-5}"
  EXTRA_GLOBAL=$(awk -F'"' '/^EXTRA_GLOBAL=/ {print $2}' "$CONFIG_FILE")
  PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2}' "$CONFIG_FILE")
  IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2}' "$CONFIG_FILE")
  PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2}' "$CONFIG_FILE")
  OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2}' "$CONFIG_FILE")
  DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2}' "$CONFIG_FILE")
  COMPOSE_PATH=$(awk -F'"' '/^COMPOSE_PATH=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_HELPER_SCRIPTS=$(awk -F'"' '/^INCLUDE_HELPER_SCRIPTS=/ {print $2}' "$CONFIG_FILE")
  IN_HEADLESS_MODE=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  [[ "$IN_HEADLESS_MODE" == true ]] || IN_HEADLESS_MODE=false
  [[ "${UU_NONINTERACTIVE:-false}" == true || "${RUN_FROM_CRON:-false}" == true ]] && IN_HEADLESS_MODE=true
  EXTRA_IN_HEADLESS="$IN_HEADLESS_MODE"
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
  USE_INTERNAL_TARGET_SELECTION=$(awk -F'"' '/^USE_INTERNAL_TARGET_SELECTION=/ {print $2}' "$CONFIG_FILE")
  USE_INTERNAL_TARGET_SELECTION="${USE_INTERNAL_TARGET_SELECTION:-false}"
  INCLUDE_PHASED_UPDATES=$(awk -F'"' '/^INCLUDE_PHASED_UPDATES=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_FSTRIM=$(awk -F'"' '/^INCLUDE_FSTRIM=/ {print $2}' "$CONFIG_FILE")
  FSTRIM_WITH_MOUNTPOINT=$(awk -F'"' '/^FSTRIM_WITH_MOUNTPOINT=/ {print $2}' "$CONFIG_FILE")
  PACMAN_ENVIRONMENT=$(awk -F'"' '/^PACMAN_ENVIRONMENT=/ {print $2}' "$CONFIG_FILE")
  if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
    export UU_FILTER_SCOPE=update
    if ! apply_only_exclude_tags ONLY EXCLUDED &&
      [[ "${TARGET_SELECTION_RUNTIME_ERROR:-false}" == true ]]; then
      printf 'Internal target selection runtime is unavailable; refusing legacy fallback.\n' >&2
      return 1
    fi
  fi
  EMAIL_USER=$(awk -F'"' '/^EMAIL_USER=/ {print $2}' "$CONFIG_FILE")
  EMAIL_USER="${EMAIL_USER:-root}"
  EMAIL_ONLY_ERROR=$(awk -F'"' '/^EMAIL_ONLY_ERROR=/ {print $2}' "$CONFIG_FILE")
  EMAIL_SENDER=$(awk -F'"' '/^EMAIL_SENDER=/ {print $2}' $CONFIG_FILE)
  EMAIL_ONLY_ERROR="${EMAIL_ONLY_ERROR:-false}"
  EMAIL_SENDER="${EMAIL_SENDER:-$USER}"
  if declare -f STATUS_MODEL_EXPAND_SENDER >/dev/null 2>&1; then
    EMAIL_SENDER=$(STATUS_MODEL_EXPAND_SENDER "$EMAIL_SENDER")
  fi
}

GET_BACKUP_STORAGE () {
  local configured_storage storage_status backup_storage

  configured_storage="$BACKUP_STORAGE"
  if [[ -n "$configured_storage" ]]; then
    storage_status=$(pvesm status -content backup 2>/dev/null |
      awk -v storage="$configured_storage" '$1 == storage {print $3; exit}')
    if [[ -z "$storage_status" ]]; then
      echo -e "❌${RD:-} Configured backup storage '$configured_storage' does not exist or does not support backups${CL:-}" >&2
      return 1
    elif [[ "$storage_status" != active ]]; then
      echo -e "❌${RD:-} Configured backup storage '$configured_storage' is not active${CL:-}" >&2
      return 1
    fi
    printf '%s\n' "$configured_storage"
    return 0
  fi

  backup_storage=$(pvesm status -content backup 2>/dev/null |
    awk 'NR > 1 && $3 == "active" {print $1; exit}')
  if [[ -z "$backup_storage" ]]; then
    echo -e "❌${RD:-} No active backup storage is available${CL:-}" >&2
    return 1
  fi
  printf '%s\n' "$backup_storage"
}

# Snapshot/Backup
CAPTURE_POST_UPDATE_STATUS() {
  local target="$1" kind="$2" refresh_rc=0 artifact_dir
  [[ "${UU_POST_UPDATE_STATUS_CAPTURE:-false}" == true ]] || return 0
  artifact_dir="${UU_REMOTE_WORK_DIR:-$TEMP_STATE_DIR}"
  if ! mkdir -p -- "$artifact_dir" "$TEMP_STATE_DIR"; then
    # A failed artifact directory setup is an incomplete capture.  Preserve a
    # non-zero marker when the local temp directory is still writable; the job
    # runner must not turn this into a completed update.
    refresh_rc=87
    printf '%s\n' "$refresh_rc" > "$TEMP_STATE_DIR/post-update-status.rc" 2>/dev/null || true
    return 0
  fi
  if [[ -x "$CHECK_SCRIPT" && -f "$LOCAL_FILES/status-model.sh" ]]; then
    # A post-update capture observes one target while the global status model
    # remains authoritative for the whole inventory.  Keep the existing
    # records and merge this fresh target observation into them.
    STATUS_MODEL_SCRIPT="$LOCAL_FILES/status-model.sh" \
    STATUS_MODEL_FILE="$LOCAL_FILES/status.json" \
    STATUS_MODEL_RECORD_FILE="$TEMP_STATE_DIR/post-update-status.records" \
    STATUS_MODEL_DIAGNOSTICS_FILE="$artifact_dir/post-update-status.diagnostics" \
    STATUS_MODEL_PARTIAL=true UU_REMOTE_DEFER_STATUS_FINISH=false TAG_OUTPUT=false \
    UU_DEFER_NOTIFICATION=true UU_EXPLICIT_TARGET_CHECK=true \
    "$CHECK_SCRIPT" "$kind" "$target" </dev/null || refresh_rc=$?
    if [[ "$refresh_rc" -eq 0 ]]; then
      if declare -F STATUS_MODEL_VALIDATE_TARGET_FILE >/dev/null 2>&1; then
        STATUS_MODEL_VALIDATE_TARGET_FILE "$LOCAL_FILES/status.json" "$target" || refresh_rc=$?
      else
        refresh_rc=87
        printf 'POST_UPDATE_CAPTURE_STATUS_VALIDATOR_UNAVAILABLE\n' >&2
      fi
    fi
  elif [[ ! -x "$CHECK_SCRIPT" ]]; then
    refresh_rc=127
    printf 'POST_UPDATE_CAPTURE_HELPER_NOT_EXECUTABLE: %s\n' "$CHECK_SCRIPT" >&2
  else
    refresh_rc=87
    printf 'POST_UPDATE_CAPTURE_STATUS_HELPER_MISSING: %s/status-model.sh\n' "$LOCAL_FILES" >&2
  fi
  printf '%s\n' "$refresh_rc" > "$artifact_dir/post-update-status.rc"
  return 0
}

CONTAINER_BACKUP () {
  local snapshot_requested="$SNAPSHOT" snapshot_output
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if RUN_PROXMOX_CAPTURE pct snapshot "$CONTAINER" "Update_$(date '+%Y%m%d_%H%M%S')"; then
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshots${CL:-}"
        LIST=$(pct listsnapshot "$CONTAINER" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          pct delsnapshot "$CONTAINER" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "✅${GN:-} Done${CL:-}"
      else
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        if grep -Eqi 'snapshot feature is not available|snapshot[^[:alnum:]]*(feature )?(is )?(not available|unsupported|not supported)|not supported[^[:alnum:]]*snapshot' <<< "$snapshot_output"; then
          echo -e "⚠️${OR:-} Snapshot not supported for LXC $CONTAINER${CL:-}"
          if [[ "$BACKUP_LXC_MP" == true ]] && pct config "$CONTAINER" | grep -q '^mp'; then
            backup_requested=true
            snapshot_requested=false
            echo -e "ℹ ${OR:-} Configured mount-point backup fallback will be used${CL:-}"
          elif [[ "$backup_requested" == true ]]; then
            snapshot_requested=false
            echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
          else
            echo -e "❌${RD:-} Guest update aborted: configured snapshot protection was not created${CL:-}"
            return 1
          fi
        elif [[ "$backup_requested" == true ]]; then
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        elif [[ "$BACKUP_LXC_MP" == true ]] && pct config "$CONTAINER" | grep -q '^mp'; then
          backup_requested=true
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Changed to backup, because of mount points${CL:-}"
        else
          echo -e "❌${RD:-} Snapshot creation failed for LXC $CONTAINER${CL:-}"
          echo -e "❌${RD:-} Guest update aborted: configured snapshot protection was not created${CL:-}"
          return 1
        fi
      fi
    fi
    if [[ "$backup_requested" == true ]]; then
      # Use BACKUP_MODE from config, default to 'stop' if not set
      MODE=${BACKUP_MODE:-stop}
      if ! STORAGE=$(GET_BACKUP_STORAGE); then
        echo -e "❌${RD:-} Backup of LXC $CONTAINER failed - no usable backup storage${CL:-}\n"
        return 1
      fi
      echo -e "💾${OR:-} Create a backup for LXC (this will take some time - please wait)${CL:-}"
      if RUN_PROXMOX_COMMAND vzdump "$CONTAINER" --mode "$MODE" --notes-template "{{guestname}} - Ultimate-Updater" --storage "$STORAGE" --compress zstd; then
        echo -e "✅${GN:-} Backup created${CL:-}\n"
      else
        echo -e "❌${RD:-} Backup of LXC $CONTAINER failed - skipping update${CL:-}\n"
        return 1
      fi
    fi
  else
    echo -e "⏩${OR:-} Snapshot and Backup skipped by the user${CL:-}"
  fi
}
VM_BACKUP () {
  local snapshot_requested="$SNAPSHOT" snapshot_output
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if RUN_PROXMOX_CAPTURE qm snapshot "$VM" "Update_$(date '+%Y%m%d_%H%M%S')"; then
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshot(s)${CL:-}"
        LIST=$(qm listsnapshot "$VM" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          qm delsnapshot "$VM" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "✅${GN:-} Done${CL:-}"
      else
        snapshot_output="$PROXMOX_CAPTURE_OUTPUT"
        if grep -Eqi 'snapshot feature is not available|snapshot[^[:alnum:]]*(feature )?(is )?(not available|unsupported|not supported)|not supported[^[:alnum:]]*snapshot' <<< "$snapshot_output"; then
          echo -e "⚠️${OR:-} Snapshot not supported for VM $VM; continuing without snapshot${CL:-}"
          snapshot_requested=false
        elif [[ "$backup_requested" == true ]]; then
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        else
          echo -e "❌${RD:-} Snapshot creation failed for VM $VM${CL:-}"
          echo -e "❌${RD:-} Guest update aborted: configured snapshot protection was not created${CL:-}"
          return 1
        fi
      fi
    fi
    if [[ "$backup_requested" == true ]]; then
      # Use BACKUP_MODE from config, default to 'stop' if not set
      MODE=${BACKUP_MODE:-stop}
      if ! STORAGE=$(GET_BACKUP_STORAGE); then
        echo -e "❌${RD:-} Backup of VM $VM failed - no usable backup storage${CL:-}"
        return 1
      fi
      echo -e "💾${OR:-} Create a backup for the VM (this will take some time - please wait)${CL:-}"
      if RUN_PROXMOX_COMMAND vzdump "$VM" --mode "$MODE" --storage "$STORAGE" --compress zstd; then
        echo -e "✅${GN:-} Backup created${CL:-}"
      else
        echo -e "❌${RD:-} Backup of VM $VM failed - skipping update${CL:-}"
        return 1
      fi
    fi
  else
    echo -e "⏩${OR:-} Snapshot and/or Backup skipped by the user${CL:-}"
  fi
}

# User scripts
USER_SCRIPTS () {
  if [[ -d $USER_SCRIPTS/$CONTAINER ]]; then
    echo -e "\n*** Run user scripts now ***\n"
    USER_SCRIPTS_LS=$(ls $USER_SCRIPTS/"$CONTAINER")
    pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/user-scripts"
    for SCRIPT in $USER_SCRIPTS_LS; do
      pct push "$CONTAINER" -- "$USER_SCRIPTS"/"$CONTAINER"/"$SCRIPT" "$LOCAL_FILES"/user-scripts/"$SCRIPT"
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && \
                                        $LOCAL_FILES/user-scripts/$SCRIPT"
    done
    pct exec "$CONTAINER" -- bash -c "rm -rf $LOCAL_FILES || true"
    echo -e "\n*** User scripts finished ***\n"
  fi
}
USER_SCRIPTS_VM () {
  if [[ -d $USER_SCRIPTS/$VM ]]; then
    echo -e "\n*** Run user scripts now ***\n"
    USER_SCRIPTS_LS=$(ls "$USER_SCRIPTS"/"$VM")
    ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p $LOCAL_FILES/user-scripts/
    for SCRIPT in $USER_SCRIPTS_LS; do
      scp "$USER_SCRIPTS"/"$VM"/"$SCRIPT" "$IP":$LOCAL_FILES/user-scripts/"$SCRIPT"
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && \
                $LOCAL_FILES/user-scripts/$SCRIPT"
    done
    ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "rm -rf $LOCAL_FILES || true"
    echo -e "\n*** User scripts finished ***\n"
  fi
}

# Script-only mode is enabled by placing a .script-only marker next to the
# guest's user scripts. The hidden marker is ignored by the normal script path.
SCRIPT_ONLY_ENABLED () {
  [[ -f "$USER_SCRIPTS/$1/.script-only" ]]
}

# API-2 updates deliberately do not execute optional or user-controlled
# scripts. These target-scoped probes are read-only and run before backup,
# snapshot, guest start, or package-manager mutation. Runtime guards remain in
# EXTRAS and update-extras.sh for older or indirect callers.
API_UPDATE_GUEST_OPTIONAL_PROBE() {
  local target="$1" kind="$2" shell_name="${3:-sh}" script output rc
  local -a assignments
  script='unsafe=false
if [ "${PIHOLE:-false}" = true ] && [ -x /usr/local/bin/pihole ]; then unsafe=true; fi
if [ "${IOBROKER:-false}" = true ] && [ -d /opt/iobroker ]; then unsafe=true; fi
if [ "${PTERODACTYL:-false}" = true ] && [ -d /var/www/pterodactyl ]; then unsafe=true; fi
if [ "${OCTOPRINT:-false}" = true ] && [ -d /root/OctoPrint ]; then unsafe=true; fi
if [ "${DOCKER_COMPOSE:-false}" = true ] && { command -v docker >/dev/null 2>&1 || [ -x /usr/local/bin/docker-compose ]; } &&
   find "${COMPOSE_PATH:-/}" -type f \( -name "docker-compose.y*ml" -o -name "compose.y*ml" \) -print -quit 2>/dev/null | grep -q .; then unsafe=true; fi
if [ "${INCLUDE_HELPER_SCRIPTS:-false}" = true ] && command -v "${COMMUNITY_UPDATE_COMMAND:-update}" >/dev/null 2>&1 &&
   grep -q community-scripts "$(command -v "${COMMUNITY_UPDATE_COMMAND:-update}")" 2>/dev/null; then unsafe=true; fi
if [ "$unsafe" = true ]; then printf unsafe; else printf safe; fi'
  assignments=(
    "PIHOLE=${PIHOLE:-false}" "IOBROKER=${IOBROKER:-false}"
    "PTERODACTYL=${PTERODACTYL:-false}" "OCTOPRINT=${OCTOPRINT:-false}"
    "DOCKER_COMPOSE=${DOCKER_COMPOSE:-false}" "COMPOSE_PATH=${COMPOSE_PATH:-/}"
    "INCLUDE_HELPER_SCRIPTS=${INCLUDE_HELPER_SCRIPTS:-false}"
    "COMMUNITY_UPDATE_COMMAND=${UU_COMMUNITY_UPDATE_COMMAND:-update}"
  )
  printf -v output 'env'
  local assignment
  for assignment in "${assignments[@]}"; do
    printf -v output '%s %q' "$output" "$assignment"
  done
  printf -v output '%s %q -c %q' "$output" "$shell_name" "$script"
  case "$kind" in
    lxc|container)
      output=$(RUN_PCT_COMMAND "$target" "$shell_name" -c "${output#* }") 2>/dev/null
      rc=$?
      ;;
    host|node)
      if [[ "$target" == "$(hostname -i 2>/dev/null | cut -d' ' -f1)" || "$target" == "$(hostname -I 2>/dev/null | awk '{print $1}')" ]]; then
        output=$(env "${assignments[@]}" "$shell_name" -c "$script") 2>/dev/null
        rc=$?
      else
        output=$(RUN_SSH_COMMAND "$target" "${INTERNAL_SSH_PORT:-${SSH_PORT:-22}}" "${INTERNAL_SSH_USER:-root}" "$shell_name" -c "${output#* }") 2>/dev/null
        rc=$?
      fi
      ;;
    vm)
      output=$(RUN_QEMU_COMMAND "$target" -- "$shell_name" -c "${output#* }") 2>/dev/null
      rc=$?
      if [[ $rc -ne 0 ]]; then
        local ip="" user="root" port="22" ssh_configured=false internal_state=3
        if [[ -f "$LOCAL_FILES/VMs/$target" ]]; then
          ssh_configured=true
          ip=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$target")
          user=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$target")
          port=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$target")
          user="${user:-root}"; port="${port:-22}"
        fi
        if declare -f INTERNAL_SSH_TARGET_STATE >/dev/null 2>&1; then
          if INTERNAL_SSH_TARGET_STATE vm "$target"; then internal_state=0; else internal_state=$?; fi
          [[ $internal_state -eq 0 ]] && ssh_configured=true
        fi
        if [[ "$ssh_configured" == true ]] && INTERNAL_SSH_RESOLVE_VM "$target" "$ip" "$user" "$port" &&
           [[ "${INTERNAL_SSH_ENABLED:-true}" == true ]]; then
          ip="${INTERNAL_SSH_HOST:-$ip}"; user="${INTERNAL_SSH_USER:-$user}"; port="${INTERNAL_SSH_PORT:-$port}"
          INTERNAL_SSH_USE_IDENTITY
          output=$(RUN_SSH_COMMAND "$ip" "$port" "$user" "$shell_name" -c "${output#* }") 2>/dev/null
          rc=$?
        fi
      fi
      ;;
    *) return 2 ;;
  esac
  [[ $rc -eq 0 && "$output" == unsafe ]] && return 0
  [[ $rc -eq 0 && "$output" == safe ]] && return 1
  return 2
}

API_UPDATE_OPTIONAL_FEATURES_ENABLED() {
  [[ "${EXTRA_GLOBAL:-false}" == true && "${EXTRA_IN_HEADLESS:-false}" == true ]] || return 1
  [[ "${PIHOLE:-false}" == true ||
    "${IOBROKER:-false}" == true ||
    "${PTERODACTYL:-false}" == true ||
    "${OCTOPRINT:-false}" == true ||
    "${DOCKER_COMPOSE:-false}" == true ||
    "${INCLUDE_HELPER_SCRIPTS:-false}" == true ]]
}

API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH() {
  local target="$1" kind="${2:-}" os_hint="${3:-}" pre_start="${4:-false}" script_dir="$USER_SCRIPTS/$1"
  local reason="" failure_code=42 failure_name=API_UNSAFE_SCRIPT_PATH probe_rc shell_name
  [[ "${UU_API_ACTION:-}" == update ]] || return 0
  UU_API_SCRIPT_PREFLIGHT_SAFE=false

  if SCRIPT_ONLY_ENABLED "$target"; then
    reason="script-only updates are not enabled for API actions"
  elif [[ -d "$script_dir" ]] && find "$script_dir" -maxdepth 1 -type f ! -name '.script-only' -print -quit 2>/dev/null | grep -q .; then
    if [[ "${EXTRA_GLOBAL:-false}" == true && "${EXTRA_IN_HEADLESS:-false}" == true ]]; then
      reason="custom update scripts are not enabled for API actions"
    fi
  fi

  if [[ -z "$reason" && "$pre_start" == true && "$kind" =~ ^(lxc|vm|container)$ && -z "$os_hint" ]]; then
    failure_code=43
    failure_name=API_PREFLIGHT_UNAVAILABLE
    reason="the guest operating system could not be determined without starting the guest"
  fi

  if [[ -z "$reason" && "$kind" =~ ^(host|node|lxc|vm|container)$ && "${EXTRA_GLOBAL:-false}" == true &&
    "${EXTRA_IN_HEADLESS:-false}" == true ]]; then
    case "${os_hint,,}" in
      ""|*debian*|*proxmox*|*ubuntu*|*devuan*|*fedora*|*centos*|*redhat*|*rhel*|*arch*|*alpine*)
        if [[ "$pre_start" == true ]]; then
          # A stopped guest cannot be probed through QGA, pct exec, or SSH.
          # Only continue before its start when the configured optional paths
          # are known to be disabled.  Otherwise fail closed.
          if API_UPDATE_OPTIONAL_FEATURES_ENABLED; then
            failure_code=43
            failure_name=API_PREFLIGHT_UNAVAILABLE
            reason="optional update path cannot be inspected while the guest is stopped"
          else
            UU_API_SCRIPT_PREFLIGHT_SAFE=true
          fi
        else
          shell_name="sh"
          if API_UPDATE_GUEST_OPTIONAL_PROBE "$target" "$kind" "$shell_name"; then
            probe_rc=0
          else
            probe_rc=$?
          fi
          case "$probe_rc" in
            0) reason="configured extra/community/helper updates would execute" ;;
            1) UU_API_SCRIPT_PREFLIGHT_SAFE=true ;;
            *)
              failure_code=43
              failure_name=API_PREFLIGHT_UNAVAILABLE
              reason="optional update path could not be inspected safely"
              ;;
          esac
        fi
        ;;
      *windows*|win*) ;;
      *)
        if [[ "$pre_start" == true || "$kind" == host || "$kind" == node ]]; then
          failure_code=43
          failure_name=API_PREFLIGHT_UNAVAILABLE
          reason="optional update path could not be classified safely"
        else
          shell_name="sh"
          [[ "${os_hint,,}" == *alpine* ]] && shell_name=ash
          failure_code=43
          failure_name=API_PREFLIGHT_UNAVAILABLE
          reason="optional update path could not be classified safely"
        fi
        ;;
    esac
  fi

  if [[ -n "$reason" ]]; then
    ERROR_CODE=$failure_code
    ID="$target"
    NAME="${NAME:-$target}"
    ERROR_MSG="$failure_name: $reason"
    echo -e "${RD:-}  ❌ $ERROR_MSG${CL:-}" >&2
    ERROR
    return "$failure_code"
  fi
  return 0
}
SCRIPT_ONLY_FILES () {
  SCRIPT_FILES=()
  while IFS= read -r -d '' SCRIPT_FILE; do
    SCRIPT_FILES+=("$SCRIPT_FILE")
  done < <(find "$1" -maxdepth 1 -type f ! -name '.script-only' -print0 2>/dev/null | sort -z)
}
SCRIPT_ONLY_LXC () {
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$CONTAINER"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for LXC $CONTAINER, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for LXC $CONTAINER"
    return 2
  fi
  echo -e "\n${OR:-}Script-only mode enabled for LXC $CONTAINER${CL:-}"
  echo -e "${OR:-}Skipping built-in OS update; running user scripts${CL:-}\n"
  SCRIPT_SHELL=bash
  [[ "$OS" == alpine ]] && SCRIPT_SHELL=ash
  if ! pct exec "$CONTAINER" -- "$SCRIPT_SHELL" -c "mkdir -p $LOCAL_FILES/user-scripts"; then
    SCRIPT_ONLY_ERROR="Could not prepare user-script directory in LXC $CONTAINER"
    return 1
  fi
  SCRIPT_ONLY_STATUS=0
  for SCRIPT_FILE in "${SCRIPT_FILES[@]}"; do
    SCRIPT=$(basename "$SCRIPT_FILE")
    if pct push "$CONTAINER" -- "$SCRIPT_FILE" "$LOCAL_FILES/user-scripts/$SCRIPT"; then
      :
    else
      SCRIPT_ONLY_STATUS=$?
      SCRIPT_ONLY_ERROR="Could not transfer user script $SCRIPT to LXC $CONTAINER (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
    if [[ "$OS" == alpine ]]; then
      pct exec "$CONTAINER" -- ash -c "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && $LOCAL_FILES/user-scripts/$SCRIPT"
    else
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && $LOCAL_FILES/user-scripts/$SCRIPT"
    fi
    SCRIPT_ONLY_STATUS=$?
    if [[ $SCRIPT_ONLY_STATUS -ne 0 ]]; then
      SCRIPT_ONLY_ERROR="User script $SCRIPT in LXC $CONTAINER failed (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
  done
  pct exec "$CONTAINER" -- "$SCRIPT_SHELL" -c "rm -rf $LOCAL_FILES/user-scripts"
  if [[ $SCRIPT_ONLY_STATUS -ne 0 ]]; then
    return "$SCRIPT_ONLY_STATUS"
  fi
  echo -e "\n${GN:-}Script-only user scripts finished${CL:-}\n"
}
SCRIPT_ONLY_SSH_VM () {
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$VM"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for VM $VM"
    return 2
  fi
  echo -e "\n${OR:-}Script-only mode enabled for VM $VM via SSH${CL:-}"
  echo -e "${OR:-}Skipping built-in OS update; running user scripts${CL:-}\n"
  if ! ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p "$LOCAL_FILES/user-scripts"; then
    SCRIPT_ONLY_ERROR="Could not prepare user-script directory in VM $VM via SSH"
    return 1
  fi
  SCRIPT_ONLY_STATUS=0
  for SCRIPT_FILE in "${SCRIPT_FILES[@]}"; do
    SCRIPT=$(basename "$SCRIPT_FILE")
    if scp "$SCRIPT_FILE" "$IP":$LOCAL_FILES/user-scripts/"$SCRIPT"; then
      :
    else
      SCRIPT_ONLY_STATUS=$?
      SCRIPT_ONLY_ERROR="Could not transfer user script $SCRIPT to VM $VM (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
    ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "chmod +x $LOCAL_FILES/user-scripts/$SCRIPT && $LOCAL_FILES/user-scripts/$SCRIPT"
    SCRIPT_ONLY_STATUS=$?
    if [[ $SCRIPT_ONLY_STATUS -ne 0 ]]; then
      SCRIPT_ONLY_ERROR="User script $SCRIPT in VM $VM failed (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
  done
  ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "rm -rf $LOCAL_FILES/user-scripts"
  [[ $SCRIPT_ONLY_STATUS -ne 0 ]] && return "$SCRIPT_ONLY_STATUS"
  echo -e "\n${GN:-}Script-only user scripts finished${CL:-}\n"
}
SCRIPT_ONLY_QEMU_VM () {
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$VM"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for VM $VM"
    return 2
  fi
  echo -e "\n${OR:-}Script-only mode enabled for VM $VM via QEMU Guest Agent${CL:-}"
  echo -e "${OR:-}Skipping built-in OS update; running user scripts${CL:-}\n"
  if ! RUN_QEMU_COMMAND "$VM" -- bash -c "mkdir -p $LOCAL_FILES/user-scripts" >/dev/null; then
    SCRIPT_ONLY_ERROR="Could not prepare user-script directory in VM $VM via QEMU Guest Agent"
    return 1
  fi
  SCRIPT_ONLY_STATUS=0
  for SCRIPT_FILE in "${SCRIPT_FILES[@]}"; do
    SCRIPT=$(basename "$SCRIPT_FILE")
    if SCRIPT_DATA=$(base64 -w0 "$SCRIPT_FILE"); then
      :
    else
      SCRIPT_ONLY_STATUS=$?
      SCRIPT_ONLY_ERROR="Could not encode user script $SCRIPT for VM $VM (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
    if RUN_QEMU_COMMAND "$VM" -- bash -c "printf '%s' '$SCRIPT_DATA' | base64 -d > '$LOCAL_FILES/user-scripts/$SCRIPT'" >/dev/null; then
      :
    else
      SCRIPT_ONLY_STATUS=$?
      SCRIPT_ONLY_ERROR="Could not transfer user script $SCRIPT to VM $VM via QEMU Guest Agent (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
    RUN_QEMU_COMMAND "$VM" -- bash -c "chmod +x '$LOCAL_FILES/user-scripts/$SCRIPT' && '$LOCAL_FILES/user-scripts/$SCRIPT'"
    SCRIPT_ONLY_STATUS=$?
    if [[ $SCRIPT_ONLY_STATUS -ne 0 ]]; then
      SCRIPT_ONLY_ERROR="User script $SCRIPT in VM $VM failed via QEMU Guest Agent (exit code $SCRIPT_ONLY_STATUS)"
      break
    fi
  done
  RUN_QEMU_COMMAND "$VM" -- bash -c "rm -rf $LOCAL_FILES/user-scripts" >/dev/null
  [[ $SCRIPT_ONLY_STATUS -ne 0 ]] && return "$SCRIPT_ONLY_STATUS"
  echo -e "\n${GN:-}Script-only user scripts finished${CL:-}\n"
}
SCRIPT_ONLY_VM () {
  SCRIPT_ONLY_FILES "$USER_SCRIPTS/$VM"
  if [[ ${#SCRIPT_FILES[@]} -eq 0 ]]; then
    echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but no user scripts were found.${CL:-}"
    SCRIPT_ONLY_ERROR="No user scripts found for VM $VM"
    return 2
  fi
  if [[ -f "$LOCAL_FILES/VMs/$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "$LOCAL_FILES/VMs/$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q -p "$SSH_VM_PORT" "$USER@$IP" exit >/dev/null 2>&1; then
      SCRIPT_ONLY_SSH_VM
      return
    fi
  fi
  QGA_ERROR=""
  if WAIT_FOR_QGA && CHECK_QGA_EXEC; then
    SCRIPT_ONLY_QEMU_VM
    return
  fi
  SCRIPT_ONLY_ERROR="${QGA_ERROR:-Neither SSH nor QEMU Guest Agent is available for VM $VM}"
  echo -e "⚠ ${OR:-}Script-only mode enabled for VM $VM, but the QEMU path is unavailable: ${SCRIPT_ONLY_ERROR}${CL:-}"
  return 1
}

# Extras
EXTRAS () {
  local extra_rc
  if [[ "${UU_API_ACTION:-}" == update && "${UU_API_SCRIPT_PREFLIGHT_SAFE:-false}" == true ]]; then
    echo -e "\n${OR:-}--- Skip optional API update paths ---${CL:-}\n"
    return 0
  fi
  if [[ "${UU_API_ACTION:-}" == update && "${EXTRA_GLOBAL:-false}" == true &&
    "${EXTRA_IN_HEADLESS:-false}" == true ]]; then
    ERROR_CODE=42
    ID="${CONTAINER:-${VM:-${ID:-unknown}}}"
    ERROR_MSG="API_UNSAFE_SCRIPT_PATH: extra/community/helper updates are not enabled for API actions"
    ERROR
    return 42
  fi
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of the user settings ---${CL:-}\n"
  elif EFFECTIVE_HEADLESS && [[ "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of Headless Mode or user settings ---${CL:-}\n"
  else
    echo -e "\n${OR:-}--- Searching for extra updates ---${CL:-}"
    if [[ "$SSH_CONNECTION" != true ]]; then
      pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/"
      pct push "$CONTAINER" -- $LOCAL_FILES/update-extras.sh $LOCAL_FILES/update-extras.sh
      pct push "$CONTAINER" -- $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf
      pct exec "$CONTAINER" -- bash -c "LOCAL_FILES='$LOCAL_FILES' chmod +x '$LOCAL_FILES/update-extras.sh' && \
                                        LOCAL_FILES='$LOCAL_FILES' '$LOCAL_FILES/update-extras.sh'; \
                                        extra_rc=\$?; rm -rf '$LOCAL_FILES'; exit \$extra_rc"
      extra_rc=$?
      [[ "$extra_rc" -eq 0 ]] || return "$extra_rc"
      USER_SCRIPTS
    # Extras in VMS with SSH_CONNECTION
    elif [[ "$USER" != root ]]; then
      echo -e "${RD:-}--- You need root user for extra updates - maybe in later relaeses possible ---${CL:-}"
    else
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p $LOCAL_FILES/
      scp $LOCAL_FILES/update-extras.sh "$IP":$LOCAL_FILES/update-extras.sh
      scp $LOCAL_FILES/update.conf "$IP":$LOCAL_FILES/update.conf
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "LOCAL_FILES='$LOCAL_FILES' chmod +x '$LOCAL_FILES/update-extras.sh' && \
                LOCAL_FILES='$LOCAL_FILES' '$LOCAL_FILES/update-extras.sh'; \
                extra_rc=\$?; rm -rf '$LOCAL_FILES'; exit \$extra_rc"
      extra_rc=$?
      [[ "$extra_rc" -eq 0 ]] || return "$extra_rc"
      USER_SCRIPTS_VM
    fi
    echo -e "${GN:-}---   Finished extra updates    ---${CL:-}"
    if [[ $WILL_STOP != true && $WELCOME_SCREEN != true ]]; then
      echo
    elif [[ "$WELCOME_SCREEN" == true ]]; then
      echo
    fi
  fi
}

# Trim Filesystem
TRIM_FILESYSTEM() {
  if [[ "$INCLUDE_FSTRIM" == true ]]; then
    local ROOT_FS
    ROOT_FS=$(df -Th "/" | awk 'NR==2 {print $2}')
    local LVS
    mapfile -t LVS < <(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$CONTAINER"'/) {gsub(/%/, "", $7); print $7}')
    if [[ ${#LVS[@]} -gt 0 ]] && [[ "$ROOT_FS" == "ext4" ]]; then
      echo -e "${OR:-}--- Trimming filesystem ---${CL:-}"
      echo -e "${RD:-}Data before trim: ${LVS[*]}%${CL:-}"
      pct fstrim "$CONTAINER" --ignore-mountpoints "$FSTRIM_WITH_MOUNTPOINT"
      local LVS_AFTER
      mapfile -t LVS_AFTER < <(lvs | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-$CONTAINER"'/) {gsub(/%/, "", $7); print $7}')
      echo -e "${GN:-}Data after trim: ${LVS_AFTER[*]}%${CL:-}\n"
      sleep 1.5
    fi
  fi
}

# Dist Upgrade
DIST_UPGRADE () {
  # debian 12 -> 13
  DEB_VERSION=$(pct exec "$CONTAINER" -- bash -c "grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '\"'")
  if [[ "$DEB_VERSION" == "12" ]]; then
    echo -e "${OR:-}✅ Debian 12 detected, want to upgrade to Debian 13?${CL:-}"
    read -p "Type [Y/y] for yes - anything else will skip: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      SNAPSHOT=
      BACKUP=true
      echo
      if ! CONTAINER_BACKUP; then
        SAFETY_FAILURE=true
        ERROR_CODE=1
        ID=$CONTAINER
        ERROR_MSG="Configured snapshot/backup protection failed; distribution upgrade aborted"
        ERROR
        return 1
      fi
      if ! DPKG_REPAIR_PREPARE "lxc:$CONTAINER" "LXC $CONTAINER" DPKG_REPAIR_RUN_LXC "$CONTAINER"; then
        SAFETY_FAILURE=true
        ERROR_CODE=1
        ID=$CONTAINER
        ERROR_MSG="${DPKG_REPAIR_ERROR:-DPKG_REPAIR_FAILED}"
        ERROR
        return 1
      fi
      echo -e "${GR:-}⏩ Upgrade to Debian 13 (Trixie) now:${CL:-}"
      echo -e "${OR:-}--- Enable stop on error ---\n${CL:-}"
      set -e
      echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get update -y"
      echo -e "${OR:-}--- APT UPGRADE ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
      echo -e "${OR:-}--- Cleaning ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y && apt-get autoclean -y"
      echo -e "\n${OR:-}--- Need 5Gig on root folder for upgrade - check it now ---${CL:-}"
      if [[ $(pct exec "$CONTAINER" -- bash -c "df --output=avail -BG / | tail -1 | sed 's/G//'") -gt 5 ]]; then
        echo -e "✅ OK\n"
        echo -e "${OR:-}⚠  This is the last step! !!! After all, check your repos !!!${CL:-}"
        echo -e "'sudo apt modernize-sources' could help you here."
        echo -e "Read and understand?"
        read -p "Type [Y/y] for yes - anything else will skip: " -r
        if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
          echo -e "${OR:-}--- Change Repo to Trixie ---\n${CL:-}"
          pct exec "$CONTAINER" -- bash -c "sed -i 's/bookworm/trixie/g' /etc/apt/sources.list"
          pct exec "$CONTAINER" -- bash -c "find /etc/apt/sources.list.d -type f -exec sed -i 's/bookworm/trixie/g' {} \;"
          echo -e "${OR:-}--- APT UPDATE for Trixie ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "apt-get update -y"
          echo -e "${OR:-}--- APT UPGRADE for Trixie ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y"
          echo -e "\n${GR:-}✅ UPGRADE to Trixie done ${CL:-}"
          echo -e "\n${OR:-}--- Restart the container now for you ---${CL:-}"
          pct exec "$CONTAINER" -- bash -c "reboot"
          echo
          return 0
        else
          echo -e "❌${BL:-} skipped\n${CL:-}"
          return 0
        fi
      else
        echo -e "❌${RD:-} need more space, pls clean up or resize disk, by yourself\n${CL:-}"
        exit 100
      fi
    else
      echo -e "❌${BL:-} skipped\n${CL:-}"
      return 0
    fi
  else
    echo -e "❌${BL:-} no Debian 12 detected\n${CL:-}"
    return 0
  fi
}

# Check Updates for Welcome-Screen
UPDATE_CHECK () {
  local status_target="" check_rc=0
  if [[ "$CHOST" == true ]]; then
    status_target="host:${HOSTNAME}"
  elif [[ "$CCONTAINER" == true ]]; then
    status_target="$CONTAINER"
  elif [[ "$CVM" == true ]]; then
    status_target="$VM"
  fi
  [[ -n "$status_target" ]] || return 0
  if declare -f CAPTURE_UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
    CAPTURE_UPDATE_PENDING_BEFORE "$status_target"
  fi
  if [[ "$WELCOME_SCREEN" == true ]]; then
    echo -e "${OR:-}--- Check Status for Welcome-Screen ---${CL:-}"
    if [[ "$CHOST" == true ]]; then
#      ssh -q -p "$SSH_PORT" "$HOSTNAME" "\"$LOCAL_FILES/check-updates.sh\" -u chost" | tee -a "$LOCAL_FILES/check-output"
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u chost | tee -a "$LOCAL_FILES/check-output"
      check_rc=${PIPESTATUS[0]}
    elif [[ "$CCONTAINER" == true ]]; then
#      ssh -q -p "$SSH_PORT" "$HOSTNAME" "\"$LOCAL_FILES/check-updates.sh\" -u ccontainer" | tee -a $LOCAL_FILES/check-output
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u ccontainer "$CONTAINER" | tee -a "$LOCAL_FILES/check-output"
      check_rc=${PIPESTATUS[0]}
    elif [[ "$CVM" == true ]]; then
      ssh -q -p "$SSH_PORT" "$HOSTNAME" "STATUS_MODEL_PARTIAL=true \"$LOCAL_FILES/check-updates.sh\" -u cvm \"$VM\"" | tee -a $LOCAL_FILES/check-output
      check_rc=${PIPESTATUS[0]}
    fi
  fi
  if [[ "$check_rc" -eq 0 ]]; then
    if declare -f RECORD_UPDATE_RESULT >/dev/null 2>&1; then
      RECORD_UPDATE_RESULT "$status_target" success 0 || return 1
    elif declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$status_target" success 0 || return 1
    else
      return 1
    fi
  else
    if declare -f RECORD_UPDATE_RESULT >/dev/null 2>&1; then
      RECORD_UPDATE_RESULT "$status_target" failed "$check_rc" || true
    elif declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$status_target" failed "$check_rc" || true
    fi
    UPDATE_FAILURE=true
    return "$check_rc"
  fi
  if [[ "$WELCOME_SCREEN" == true ]]; then
    echo -e "${GN:-}---          Finished check         ---${CL:-}\n"
    [[ "$WILL_STOP" != true ]] && echo
  else
    echo
  fi
}

UPDATE_REBOOT_STATUS_FRESH() {
  local target="$1" status_file="${STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}"
  python3 - "$status_file" "$target" "$UPDATE_RUN_STARTED_AT" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, target, started = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as source:
        payload = json.load(source)
    record = next(item for item in payload.get("targets", [])
                  if isinstance(item, dict) and str(item.get("id")) == target)
    last_update = record.get("last_update")
    if not isinstance(last_update, dict) or last_update.get("status") != "success":
        raise ValueError
    if last_update.get("reboot_required") is not True:
        raise SystemExit(1)
    stamp = datetime.fromisoformat(str(last_update.get("timestamp", "")).replace("Z", "+00:00"))
    run_start = datetime.fromisoformat(started.replace("Z", "+00:00"))
    if stamp.tzinfo is None or run_start.tzinfo is None or stamp < run_start:
        raise SystemExit(1)
except (OSError, ValueError, StopIteration, TypeError, KeyError, json.JSONDecodeError):
    raise SystemExit(2)
raise SystemExit(0)
PY
}

AUTO_REBOOT_GUEST() {
  local kind="$1" target="$2" was_stopped="${3:-false}" reboot_rc message
  [[ "${REBOOT_IF_NEEDED:-false}" == true ]] || return 0
  if ! UPDATE_REBOOT_STATUS_FRESH "$target"; then
    return 0
  fi
  if [[ "${UU_API_ACTION:-}" == update || "${UU_API_REBOOT_ALLOWED:-true}" != true ]]; then
    echo -e "${OR:-}Reboot required for $target; automatic reboot is disabled for API updates.${CL:-}"
    return 0
  fi
  if [[ "$was_stopped" == true ]]; then
    echo -e "${OR:-}Reboot required for $target; preserving its originally stopped state.${CL:-}"
    return 0
  fi
  case "$kind" in
    lxc) echo -e "${OR:-}--- AUTOMATIC LXC REBOOT ---${CL:-}"; RUN_PROXMOX_COMMAND pct reboot "$target"; reboot_rc=$? ;;
    vm) echo -e "${OR:-}--- AUTOMATIC VM REBOOT ---${CL:-}"; RUN_PROXMOX_COMMAND qm reboot "$target"; reboot_rc=$? ;;
    *)
      echo -e "${OR:-}Automatic reboot is not supported safely for target $target; manual reboot may be required.${CL:-}" >&2
      return 0
      ;;
  esac
  if [[ "$reboot_rc" -ne 0 ]]; then
    message="Automatic reboot failed for $target (exit code $reboot_rc)"
    ERROR_CODE="$reboot_rc"
    ID="$target"
    NAME="${NAME:-$target}"
    ERROR_MSG="$message"
    ERROR
    declare -f STATUS_MODEL_REBOOT_FAILURE >/dev/null 2>&1 &&
      STATUS_MODEL_REBOOT_FAILURE "$target" "$reboot_rc" "$message" || true
    return "$reboot_rc"
  fi
  echo -e "${GN:-}Automatic reboot requested for $target.${CL:-}"
  return 0
}

# Wait for bootup / reboot
# Container
WAIT_FOR_BOOTUP_LXC () {
  MAX_RETRIES=10
  COUNT=1
  BOOT_SHELL=bash
  [[ "$(pct config "$CONTAINER" | awk '/^ostype/ {print $2}')" == alpine ]] && BOOT_SHELL=ash
  sleep "$LXC_START_DELAY"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if pct exec "$CONTAINER" -- "$BOOT_SHELL" -c "exit" >/dev/null 2>&1; then
      echo -e "✅${GN:-} $CONTAINER reachable (tryout $COUNT)\n${CL:-}"
      break
    else
      echo -e "ℹ  Tryout $COUNT/$MAX_RETRIES failed"
      sleep "$LXC_START_DELAY"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    echo -e "❌${RD:-} Connection to $CONTAINER after $MAX_RETRIES failed.${CL:-}\n"
    return 1
  fi
}
# VM-SSH
WAIT_FOR_BOOTUP_SSH () {
  MAX_RETRIES=10
  COUNT=1
  sleep "$SSH_START_DELAY_TIME"
  while [ $COUNT -le $MAX_RETRIES ]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q -p "$SSH_VM_PORT" "$USER@$IP" exit >/dev/null 2>&1; then
      echo -e "✅${GN:-} $VM reachable (tryout $COUNT)\n${CL:-}"
      break
    else
      echo -e "ℹ  Tryout $COUNT/$MAX_RETRIES failed"
      sleep "$SSH_START_DELAY_TIME"
    fi
    COUNT=$((COUNT+1))
  done
  if [ $COUNT -gt $MAX_RETRIES ]; then
    echo -e "❌${RD:-} Connection to $VM after $MAX_RETRIES failed.${CL:-}\n"
    return 1
  fi
}

# QEMU Guest Agent readiness
WAIT_FOR_QGA () {
  local QGA_MAX_WAIT=180
  local QGA_INTERVAL=2
  local QGA_DEADLINE=$((SECONDS + QGA_MAX_WAIT))

  if [[ "$START_WAITING" == true ]]; then
    echo -e "⏳${OR:-} Wait for QEMU Guest Agent on VM $VM (up to ${QGA_MAX_WAIT}s)${CL:-}\n"
  fi
  while (( SECONDS < QGA_DEADLINE )); do
    if qm agent "$VM" ping >/dev/null 2>&1; then
      return 0
    fi
    sleep "$QGA_INTERVAL"
  done
  QGA_ERROR="Timed out waiting for QEMU Guest Agent on VM $VM."
  return 1
}

QGA_EXEC_SCRIPT="${UU_QGA_EXEC_SCRIPT:-$LOCAL_FILES/qga-guest-exec.sh}"
[[ -f "$QGA_EXEC_SCRIPT" ]] || QGA_EXEC_SCRIPT="$(dirname -- "${BASH_SOURCE[0]}")/qga-guest-exec.sh"
if [[ -f "$QGA_EXEC_SCRIPT" ]]; then
  # shellcheck source=/dev/null
  source "$QGA_EXEC_SCRIPT"
else
  QEMU_GUEST_EXEC() {
    QEMU_EXEC_STDOUT=""
    QEMU_EXEC_STDERR=""
    QEMU_EXEC_OUTPUT="QGA guest-exec helper is missing"
    QEMU_EXEC_EXITCODE=""
    QEMU_EXEC_TRANSPORT_RC=1
  }
  QEMU_GUEST_EXEC_READONLY() { QEMU_GUEST_EXEC "$@"; }
fi

# Run a QEMU command once, display its output, and return the guest exit code.
# A non-zero transport status is returned unchanged.
RUN_QEMU_COMMAND () {
  QEMU_GUEST_EXEC "$@"
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    [[ -n "$QEMU_EXEC_OUTPUT" ]] && printf '%s\n' "$QEMU_EXEC_OUTPUT"
    return "$QEMU_EXEC_TRANSPORT_RC"
  fi
  printf '%s' "$QEMU_EXEC_STDOUT"
  if [[ -n "$QEMU_EXEC_STDERR" ]]; then
    [[ -n "$QEMU_EXEC_STDOUT" && "${QEMU_EXEC_STDOUT: -1}" != $'\n' ]] && printf '\n'
    printf '%s' "$QEMU_EXEC_STDERR"
  fi
  return "$QEMU_EXEC_EXITCODE"
}

RUN_QEMU_DURABLE () {
  QEMU_GUEST_EXEC_DURABLE "$@"
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 ]]; then
    [[ -n "$QEMU_EXEC_OUTPUT" ]] && printf '%s\n' "$QEMU_EXEC_OUTPUT"
    return "$QEMU_EXEC_TRANSPORT_RC"
  fi
  printf '%s' "$QEMU_EXEC_STDOUT"
  return "$QEMU_EXEC_EXITCODE"
}

CHECK_QGA_EXEC () {
  QEMU_GUEST_EXEC_READONLY "$VM" -- true
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]; then
    return 0
  fi
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 ]]; then
    QGA_ERROR="QEMU Guest Agent command failed on VM $VM (guest exit code $QEMU_EXEC_EXITCODE): $QEMU_EXEC_OUTPUT"
  else
    QGA_ERROR="QEMU Guest Agent guest-exec failed on VM $VM (transport exit code $QEMU_EXEC_TRANSPORT_RC): $QEMU_EXEC_OUTPUT"
  fi
  return 1
}

############################
########## HOST ############
############################

# Host Update Start
HOST_UPDATE_START () {
  USE_INTERNAL_TARGET_SELECTION="${USE_INTERNAL_TARGET_SELECTION:-false}"
  local host_selected=true host_required=true
  if [[ "$USE_INTERNAL_TARGET_SELECTION" == true ]] && declare -f TARGET_SELECTION_ALLOWS >/dev/null 2>&1; then
    UU_FILTER_SCOPE=update UU_FILTER_ELIGIBLE_IDS="$(for host in $HOSTS; do printf 'host:%s ' "$(awk -v address="$host" '/name[[:space:]]*:/ { name=$2 } /ring0_addr[[:space:]]*:/ && $2 == address { print name; found=1; exit } END { if (!found) print address }' /etc/pve/corosync.conf 2>/dev/null)"; done)" export UU_FILTER_SCOPE UU_FILTER_ELIGIBLE_IDS
  fi
  if [[ "$RICM" != true ]]; then true > $LOCAL_FILES/check-output; fi
  for HOST in $HOSTS; do
    HOST_NODE=$(awk -v address="$HOST" '/name[[:space:]]*:/ { name=$2 } /ring0_addr[[:space:]]*:/ && $2 == address { print name; found=1; exit } END { if (!found) print address }' /etc/pve/corosync.conf 2>/dev/null)
    host_selected=true
    host_required=true
    if [[ "$USE_INTERNAL_TARGET_SELECTION" == true ]] && declare -f TARGET_SELECTION_ALLOWS >/dev/null 2>&1; then
      TARGET_SELECTION_ALLOWS update "host:$HOST_NODE" "$UU_FILTER_ELIGIBLE_IDS" || host_selected=false
      TARGET_SELECTION_HOST_REQUIRED update "host:$HOST_NODE" || host_required=false
      [[ "$host_required" == true ]] || continue
    fi
    INTERNAL_SSH_RESOLVE_NODE "$HOST_NODE" "$HOST" "$SSH_PORT" || { UPDATE_FAILURE=true; continue; }
    [[ "${INTERNAL_SSH_ENABLED:-true}" == true ]] || { UPDATE_FAILURE=true; continue; }
    HOST="${INTERNAL_SSH_HOST:-$HOST}"; SSH_PORT="${INTERNAL_SSH_PORT:-$SSH_PORT}"; INTERNAL_SSH_USE_IDENTITY
    # Check if Host/Node is available
    if ssh -q -p "$SSH_PORT" "$HOST" test >/dev/null 2>&1; [ $? -eq 255 ]; then
      echo -e "⏩ ${OR:-}Skip Host${CL:-} : ${GN:-}$HOST${CL:-} ${OR:-}- can't connect${CL:-}\n"
      UPDATE_FAILURE=true
    else
      [[ "$host_selected" == true ]] || export UU_INTERNAL_SKIP_HOST_TARGET=true
      UPDATE_HOST "$HOST"
      local host_update_rc=$?
      if [[ "$host_update_rc" -eq "${UPDATE_WARNING_RC:-10}" ]]; then
        UPDATE_WARNING=true
      elif [[ "$host_update_rc" -ne 0 ]]; then
        UPDATE_FAILURE=true
      fi
      unset UU_INTERNAL_SKIP_HOST_TARGET
    fi
  done
}

# Host Update
UPDATE_HOST () {
  HOST=$1
  local remote_update_env="" remote_handoff_env=""
  local remote_operation_id=""
  local remote_workspace="" remote_job_unit="" remote_state_dir=""
  local remote_started_at="" remote_finished_at="" remote_state=""
  local remote_finalize_command="" remote_handoff_rc=0
  local apt_count_file rpm_count_file package_count_file product_metadata_file source
  REQUIRE_PACKAGE_DATA_INVALIDATION || return 1
  [[ "${UU_INTERNAL_SKIP_HOST_TARGET:-false}" == true ]] && remote_update_env="UU_INTERNAL_SKIP_HOST_TARGET=true "
  if [[ "${UU_API_ACTION:-}" == update ]]; then
    API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH "$HOST" host proxmox || return $?
  fi
  START_HOST=$(hostname -i | cut -d ' ' -f1)
  if [[ "$HOST" != "$START_HOST" ]]; then
    remote_operation_id=$(STATUS_MODEL_NEW_OPERATION_ID) || return 1
  fi
  MARK_PACKAGE_DATA_INVALIDATED "host:${HOST_NODE:-$(hostname -s 2>/dev/null || hostname)}" host "${HOST_NODE:-$(hostname -s 2>/dev/null || hostname)}" "$remote_operation_id" || return $?
  if [[ "$HOST" != "$START_HOST" ]]; then
    remote_workspace="/tmp/ultimate-updater-update-node-$$-$RANDOM-$RANDOM"
    remote_job_unit="ultimate-updater-update-node-${HOST_NODE:-remote}-$$-$RANDOM"
    remote_state_dir="${UU_REMOTE_JOB_STATE_DIR:-/var/lib/ultimate-updater/jobs}"
    remote_started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf -v remote_handoff_env \
      'UU_REMOTE_NODE_HANDOFF=true UU_REMOTE_WORK_DIR=%q UU_REMOTE_STATE_DIR=%q UU_REMOTE_JOB_UNIT=%q WELCOME_SCREEN=true ' \
      "$remote_workspace" "$remote_state_dir" "$remote_job_unit"
    if [[ "${UU_API_ACTION:-}" == update ]]; then
      remote_update_env+='UU_API_ACTION=update UU_NONINTERACTIVE=true UU_API_REBOOT_ALLOWED=false '
    elif [[ "${UU_NONINTERACTIVE:-false}" == true ]]; then
      remote_update_env+='UU_NONINTERACTIVE=true '
    fi
    printf -v operation_env 'UU_PACKAGE_MUTATION_OPERATION_ID=%q ' "$remote_operation_id"
    remote_update_env+="$operation_env"
    ssh -q -p "$SSH_PORT" "$HOST" mkdir -p $LOCAL_FILES/temp
    ssh -q -p "$SSH_PORT" "$HOST" "mkdir -p $(printf '%q' "$remote_workspace") $(printf '%q' "$remote_state_dir")"
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf ]]; then cp -p $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf.uu-backup; else rm -f $LOCAL_FILES/update.conf.uu-backup; fi"
    scp "$0" "$HOST":$LOCAL_FILES/update
    scp $LOCAL_FILES/update-extras.sh "$HOST":$LOCAL_FILES/update-extras.sh
    scp $LOCAL_FILES/update.conf "$HOST":$LOCAL_FILES/update.conf
    if [[ -f $LOCAL_FILES/update.conf.dist ]]; then
      scp $LOCAL_FILES/update.conf.dist "$HOST":$LOCAL_FILES/update.conf.dist
    fi
    apt_count_file="$LOCAL_FILES/apt-count.py"
    apt_count_shell_file="$LOCAL_FILES/apt-count.sh"
    rpm_count_file="$LOCAL_FILES/rpm-count.py"
    package_count_file="$LOCAL_FILES/package-count.sh"
    product_metadata_file="$LOCAL_FILES/product-metadata.sh"
    [[ -f "$apt_count_file" ]] || apt_count_file="$SCRIPT_DIR/apt-count.py"
    [[ -f "$apt_count_shell_file" ]] || apt_count_shell_file="$SCRIPT_DIR/apt-count.sh"
    [[ -f "$rpm_count_file" ]] || rpm_count_file="$SCRIPT_DIR/rpm-count.py"
    [[ -f "$package_count_file" ]] || package_count_file="$SCRIPT_DIR/package-count.sh"
    [[ -f "$product_metadata_file" ]] || product_metadata_file="$SCRIPT_DIR/product-metadata.sh"
    if [[ ! -f "$product_metadata_file" ]]; then
      ssh -q -p "$SSH_PORT" "$HOST" "rm -rf -- $(printf '%q' "$remote_workspace")" >/dev/null 2>&1 || true
      echo "Could not stage product metadata for remote host $HOST" >&2
      return 6
    fi
    for source in "$LOCAL_FILES/check-updates.sh" "$LOCAL_FILES/status-model.sh" \
      "$apt_count_file" "$apt_count_shell_file" "$rpm_count_file" "$package_count_file" \
      "$product_metadata_file"; do
      [[ -f "$source" ]] || continue
      scp "$source" "$HOST:$LOCAL_FILES/$(basename -- "$source")"
    done
    if [[ -f "$LOCAL_FILES/notification-apprise.py" ]]; then
      scp "$LOCAL_FILES/notification-apprise.py" "$HOST:$LOCAL_FILES/notification-apprise.py"
    fi
    if [[ -f "$LOCAL_FILES/check-output" ]]; then
      scp "$LOCAL_FILES/check-output" "$HOST:$LOCAL_FILES/check-output"
    fi
    scp /etc/ultimate-updater/temp/exec_host "$HOST":/etc/ultimate-updater/temp
    scp -r $LOCAL_FILES/VMs/ "$HOST":$LOCAL_FILES/
    if [[ -f $LOCAL_FILES/tag-filter.sh ]]; then
      scp $LOCAL_FILES/tag-filter.sh "$HOST":$LOCAL_FILES/tag-filter.sh
    fi
    if [[ -f "$LOCAL_FILES/target-selection.sh" ]]; then
      scp "$LOCAL_FILES/target-selection.sh" "$HOST":$LOCAL_FILES/target-selection.sh
    fi
    if [[ "$USE_INTERNAL_TARGET_SELECTION" == true && -f "${UU_TARGET_SELECTION_FILE:-$LOCAL_FILES/target-selection.json}" ]]; then
      scp "${UU_TARGET_SELECTION_FILE:-$LOCAL_FILES/target-selection.json}" "$HOST":$LOCAL_FILES/target-selection.json
    fi
    if [[ -f "$LOCAL_FILES/target-runtime.sh" ]]; then
      scp "$LOCAL_FILES/target-runtime.sh" "$HOST":$LOCAL_FILES/target-runtime.sh
    fi
    if [[ -f "$LOCAL_FILES/internal-ssh.sh" ]]; then
      scp "$LOCAL_FILES/internal-ssh.sh" "$HOST":$LOCAL_FILES/internal-ssh.sh
    fi
    if [[ -f "$LOCAL_FILES/cluster-target.sh" ]]; then
      scp "$LOCAL_FILES/cluster-target.sh" "$HOST":$LOCAL_FILES/cluster-target.sh
    fi
    if [[ -f "$LOCAL_FILES/qga-guest-exec.sh" ]]; then
      scp "$LOCAL_FILES/qga-guest-exec.sh" "$HOST":$LOCAL_FILES/qga-guest-exec.sh
    fi
  fi
  if EFFECTIVE_HEADLESS; then
    ssh -q -p "$SSH_PORT" "$HOST" "${remote_update_env}${remote_handoff_env}bash -s" < "$0" -- "-s -c host"
    REMOTE_UPDATE_STATUS=$?
  elif [[ "$WELCOME_SCREEN" == true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" "${remote_update_env}${remote_handoff_env}bash -s" < "$0" -- "-c -w host"
    REMOTE_UPDATE_STATUS=$?
  else
    ssh -q -p "$SSH_PORT" "$HOST" "${remote_update_env}${remote_handoff_env}bash -s" < "$0" -- "-c host"
    REMOTE_UPDATE_STATUS=$?
  fi
  if [[ "$HOST" != "$START_HOST" ]]; then
    if [[ -n "$remote_workspace" ]]; then
      remote_finished_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      [[ "$REMOTE_UPDATE_STATUS" -eq 0 ]] && remote_state=completed || remote_state=failed
      printf -v remote_finalize_command \
        'set -e; [[ -s %q/status.json ]] || exit 86; cp -- %q/status.json %q/status.json; printf %q %q > %q/post-update-status.rc; { printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; printf %q %q; } > %q/%q.state' \
        "$LOCAL_FILES" "$LOCAL_FILES" "$remote_workspace" \
        '%s\n' "$REMOTE_UPDATE_STATUS" "$remote_workspace" \
        '%s\n' schema_version=1 \
        '%s\n' "unit=$remote_job_unit" \
        '%s\n' "target=node-${HOST_NODE:-remote}" \
        '%s\n' "state=$remote_state" \
        '%s\n' "started_at=$remote_started_at" \
        '%s\n' "finished_at=$remote_finished_at" \
        '%s\n' "exit_code=$REMOTE_UPDATE_STATUS" \
        '%s\n' type=update \
        '%s\n' source=remote \
        '%s\n' interactive=false \
        "$remote_state_dir" "$remote_job_unit"
      if ! ssh -q -p "$SSH_PORT" "$HOST" "$remote_finalize_command"; then
        remote_handoff_rc=1
      elif [[ -x "$LOCAL_FILES/job-runner.sh" ]] &&
        ! "$LOCAL_FILES/job-runner.sh" record-remote "$remote_job_unit" \
          "node-${HOST_NODE:-remote}" "${HOST_NODE:-remote}" "$HOST" "$SSH_PORT" "$remote_workspace"; then
        remote_handoff_rc=1
      fi
      if [[ "$remote_handoff_rc" -ne 0 ]]; then
        echo -e "${RD:-}⚠ Could not register structured remote update result for $HOST${CL:-}" >&2
        UPDATE_FAILURE=true
      fi
    fi
    # Collect the updated welcome-screen state from the remote node using the
    # already trusted controller -> node SSH direction. Requiring the remote
    # node to initiate a reverse SCP can fail when the controller host key is
    # not present in the remote root user's known_hosts.
    if [[ "$WELCOME_SCREEN" == true ]]; then
      if ! scp "$HOST:$LOCAL_FILES/check-output" "$LOCAL_FILES/check-output"; then
        echo -e "${RD:-}⚠ Could not retrieve check-output from remote host $HOST${CL:-}" >&2
      fi
    fi
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf.uu-backup ]]; then mv -f $LOCAL_FILES/update.conf.uu-backup $LOCAL_FILES/update.conf; else rm -f $LOCAL_FILES/update.conf; fi"
  fi
  MARK_PACKAGE_DATA_MUTATION_COMPLETE "host:${HOST_NODE:-$(hostname -s 2>/dev/null || hostname)}" host "${HOST_NODE:-$(hostname -s 2>/dev/null || hostname)}" "$remote_operation_id" || UPDATE_FAILURE=true
  return "${REMOTE_UPDATE_STATUS:-0}"
}

# shellcheck disable=SC2015
UPDATE_HOST_ITSELF () {
  if declare -f CAPTURE_UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
    CAPTURE_UPDATE_PENDING_BEFORE "host:$(hostname -s 2>/dev/null || hostname)"
  fi
  REQUIRE_PACKAGE_DATA_INVALIDATION || return 1
  MARK_PACKAGE_DATA_INVALIDATED "host:$(hostname -s 2>/dev/null || hostname)" host "$(hostname -s 2>/dev/null || hostname)" || {
    UPDATE_FAILURE=true
    return 1
  }
  echo -e "${OR:-}--- PVE UPDATE ---${CL:-}" && pveupdate || true
  if ! DPKG_REPAIR_PREPARE "host:$(hostname -s 2>/dev/null || hostname)" \
      "Proxmox host (no snapshot/backup protection)" DPKG_REPAIR_RUN_LOCAL; then
    ERROR_CODE=1
    ID=$HOSTNAME
    NAME=$HOSTNAME
    ERROR_MSG="${DPKG_REPAIR_ERROR:-DPKG_REPAIR_FAILED}"
    ERROR
    return
  fi
  if EFFECTIVE_HEADLESS; then
    echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}" && \
    RUN_UPDATE_COMMAND APT_COMMAND "${DPKG_OPTIONS[@]}" dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
  else
    if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      RUN_UPDATE_COMMAND APT_COMMAND "${DPKG_OPTIONS[@]}" dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      RUN_UPDATE_COMMAND APT_COMMAND "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
    fi
  fi
  echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}" && \
  RUN_UPDATE_COMMAND APT_COMMAND --purge autoremove -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
  if [[ $ERROR_CODE != "" ]]; then return; fi
  echo
  CHOST="true"
  UPDATE_CHECK
  CHOST=""
}

############################
######## CONTAINER #########
############################

# Container Update Start
CONTAINER_UPDATE_START () {
  USE_INTERNAL_TARGET_SELECTION="${USE_INTERNAL_TARGET_SELECTION:-false}"
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  if [[ "$USE_INTERNAL_TARGET_SELECTION" == true ]] && declare -f TARGET_SELECTION_ALLOWS >/dev/null 2>&1; then
    UU_FILTER_SCOPE=update UU_FILTER_ELIGIBLE_IDS="$CONTAINERS" export UU_FILTER_SCOPE UU_FILTER_ELIGIBLE_IDS
  fi
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    ERROR_CODE=""
    if [[ "$SINGLE_UPDATE" == true && "$CONTAINER" != "$ONLY" ]]; then
      continue
    elif [[ "$SINGLE_UPDATE" != true && "$USE_INTERNAL_TARGET_SELECTION" == true ]] && ! TARGET_SELECTION_ALLOWS update "$CONTAINER" "$CONTAINERS"; then
      echo -e "⏩${BL:-} Skipped LXC $CONTAINER by internal target selection${CL:-}\n\n"
    elif [[ "$SINGLE_UPDATE" != true ]] && guest_id_matches "$EXCLUDED" "$CONTAINER"; then
      echo -e "⏩${BL:-} Skipped LXC $CONTAINER by update filter (excluded)${CL:-}\n\n"
    elif [[ "$SINGLE_UPDATE" != true && "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$CONTAINER"; then
      echo -e "⏩${BL:-} Skipped LXC $CONTAINER by update filter (not selected)${CL:-}\n\n"
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      echo -e "⏩ ${OR:-}LXC $CONTAINER is a template - skip update${CL:-}\n\n"
      continue
    else
      if [[ "${UU_API_ACTION:-}" == update ]] &&
        declare -f API_UPDATE_TARGET_IDENTITY_GUARD >/dev/null 2>&1 &&
        ! API_UPDATE_TARGET_IDENTITY_GUARD "$CONTAINER" lxc; then
        UPDATE_FAILURE=true
        continue
      fi
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" == true ]]; then
        if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
          UPDATE_TARGET_CAPABILITY_GUARD "$CONTAINER" lxc
          capability_rc=$?
          [[ "$capability_rc" -eq 0 ]] || { [[ "$capability_rc" -eq 21 ]] || UPDATE_FAILURE=true; continue; }
        fi
        if [[ "${UU_API_ACTION:-}" == update ]]; then
          OS=$(pct config "$CONTAINER" 2>/dev/null | awk '/^ostype/ {print $2; exit}')
          NAME="LXC $CONTAINER"
          if ! API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH "$CONTAINER" lxc "$OS" true; then
            UPDATE_FAILURE=true
            continue
          fi
        fi
        if ! REQUIRE_PACKAGE_DATA_INVALIDATION ||
          ! MARK_PACKAGE_DATA_INVALIDATED "$CONTAINER" lxc; then
          UPDATE_FAILURE=true
          continue
        fi
        # Start the container
        WILL_STOP="true"
        echo -e " ▶${GN:-} Starting LXC ${BL:-}$CONTAINER ${CL:-}"
        RUN_PROXMOX_COMMAND pct start "$CONTAINER"
        echo -e "⏳${GN:-} Waiting for LXC ${BL:-}$CONTAINER${CL:-}${GN:-} to start ${CL:-}"
#        sleep "$LXC_START_DELAY"
        if WAIT_FOR_BOOTUP_LXC; then
          SINGLE_TARGET_EXECUTED=true
          if declare -F CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE >/dev/null 2>&1 &&
            ! CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE "$CONTAINER" lxc; then
            ERROR_CODE=96
            ID=$CONTAINER
            NAME="LXC $CONTAINER"
            ERROR_MSG="PENDING_BEFORE_UNAVAILABLE: fresh package baseline could not be collected after starting LXC $CONTAINER"
            RECORD_UPDATE_RESULT "$CONTAINER" failed 96 || true
            ERROR
          else
            UPDATE_CONTAINER "$CONTAINER"
          fi
          MARK_PACKAGE_DATA_MUTATION_COMPLETE "$CONTAINER" lxc || UPDATE_FAILURE=true
          CAPTURE_POST_UPDATE_STATUS "$CONTAINER" ccontainer
          CCONTAINER=""
        else
          ERROR_CODE=$?
          ID=$CONTAINER
          NAME="LXC $CONTAINER"
          ERROR_MSG="LXC $CONTAINER did not become reachable after the boot wait timeout"
          ERROR
        fi
        # Stop the container
        echo -e "⏹ ${GN:-} Shutting down LXC ${BL:-}$CONTAINER ${CL:-}\n\n"
        if declare -F RESTORE_STOPPED_LXC >/dev/null 2>&1; then
          if ! RESTORE_STOPPED_LXC "$CONTAINER"; then
            UPDATE_FAILURE=true
            ERROR_CODE=1
            ID=$CONTAINER
            NAME="LXC $CONTAINER"
            ERROR_MSG="LXC $CONTAINER did not return to stopped state after update"
            ERROR
          fi
        else
          RUN_PROXMOX_COMMAND pct shutdown "$CONTAINER" &
        fi
        WILL_STOP="false"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER because stopped containers are disabled${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" == true ]]; then
        if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
          UPDATE_TARGET_CAPABILITY_GUARD "$CONTAINER" lxc
          capability_rc=$?
          [[ "$capability_rc" -eq 0 ]] || { [[ "$capability_rc" -eq 21 ]] || UPDATE_FAILURE=true; continue; }
        fi
        SINGLE_TARGET_EXECUTED=true
        UPDATE_CONTAINER "$CONTAINER"
        MARK_PACKAGE_DATA_MUTATION_COMPLETE "$CONTAINER" lxc || UPDATE_FAILURE=true
        CAPTURE_POST_UPDATE_STATUS "$CONTAINER" ccontainer
        AUTO_REBOOT_GUEST lxc "$CONTAINER" false || UPDATE_FAILURE=true
        CCONTAINER=""
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER because running containers are disabled${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
  rm -rf "$TEMP_STATE_DIR/temp"
}

# Container Update
UPDATE_CONTAINER () {
  CONTAINER=$1
  CCONTAINER="true"
  echo 'CONTAINER="'"$CONTAINER"'"' > "$TEMP_STATE_DIR/var"
  OS=$(pct config "$CONTAINER" | awk '/^ostype/' - | cut -d' ' -f2)
  if declare -f CAPTURE_UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
    CAPTURE_UPDATE_PENDING_BEFORE "$CONTAINER"
  fi
  if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
    UPDATE_TARGET_CAPABILITY_GUARD "$CONTAINER" lxc
    local capability_rc=$?
    [[ "$capability_rc" -eq 0 ]] || { CCONTAINER=""; return "$capability_rc"; }
  fi
  NAME=$(pct exec "$CONTAINER" hostname)
  API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH "$CONTAINER" lxc "$OS" || return $?
  REQUIRE_PACKAGE_DATA_INVALIDATION || return 1
  MARK_PACKAGE_DATA_INVALIDATED "$CONTAINER" lxc || return $?
#  if [[ "$OS" =~ centos ]]; then
#    NAME=$(pct exec "$CONTAINER" hostnamectl | grep 'hostname' | tail -n +2 | rev |cut -c -11 | rev)
#  else
#    NAME=$(pct exec "$CONTAINER" hostname)
#  fi
  if [[ "$CHECK_DIST" != true ]]; then
    echo -e "🔄${GN:-} Updating LXC ${BL:-}$CONTAINER${CL:-} : ${GN:-}$NAME${CL:-}\n"
  else
    echo -e "🔄${GN:-} Check dist upgrade for LXC ${BL:-}$CONTAINER${CL:-} : ${GN:-}$NAME${CL:-}"
  fi
  # Check Internet connection
  if [[ "$OS" != alpine ]]; then
    if ! RUN_PCT_COMMAND "$CONTAINER" bash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"; then
      echo -e "${OR:-} ❌ Internet check fail - skip this container${CL:-}\n"
      UPDATE_FAILURE=true
      return
    fi
#  elif [[ "$OS" == alpine ]]; then
#    if ! pct exec "$CONTAINER" -- ash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"; then
#      echo -e "${OR:-} Internet is not reachable - skip the update${CL:-}\n"
#      return
#    fi
  fi
  # Backup
  if [[ "$CHECK_DIST" != true ]]; then
    echo -e "💾${OR:-} Start Snapshot and/or Backup${CL:-}"
    if ! CONTAINER_BACKUP; then
      SAFETY_FAILURE=true
      ERROR_CODE=1
      ID=$CONTAINER
      ERROR_MSG="Configured snapshot/backup protection failed; LXC update aborted"
      ERROR
      return 1
    fi
    echo
  fi
  if SCRIPT_ONLY_ENABLED "$CONTAINER"; then
    SCRIPT_ONLY_LXC || {
      ERROR_CODE=$?
      ID=$CONTAINER
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    if [[ -z "${ERROR_CODE:-}" ]]; then
      RECORD_UPDATE_RESULT "$CONTAINER" success 0 || return 1
    fi
    CCONTAINER=""
    return
  fi
  # Run dist-upgrade
  if [[ $CHECK_DIST == true && $OS =~ debian ]]; then
    DIST_UPGRADE
    local dist_result=$?
    if declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      if [[ $dist_result -eq 0 ]]; then
        RECORD_UPDATE_RESULT "$CONTAINER" success 0 || return 1
      else
        RECORD_UPDATE_RESULT "$CONTAINER" failed "$dist_result" || return 1
      fi
    fi
    return "$dist_result"
  elif [[ "$CHECK_DIST" == true ]]; then
    echo -e "${OR:-} ❌ Distribution not supported\n${CL:-}"
    RECORD_UPDATE_RESULT "$CONTAINER" unsupported 21 || return 1
    return 0
  fi
  # Run update
  # shellcheck disable=SC2015
  if [[ "${OS,,}" =~ ubuntu|debian|devuan ]]; then
    if ! DPKG_REPAIR_PREPARE "lxc:$CONTAINER" "LXC $CONTAINER" DPKG_REPAIR_RUN_LXC "$CONTAINER"; then
      SAFETY_FAILURE=true
      ERROR_CODE=1
      ID=$CONTAINER
      ERROR_MSG="${DPKG_REPAIR_ERROR:-DPKG_REPAIR_FAILED}"
      ERROR
      return 1
    fi
    echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
    # Check APT in Container for Unifi before update
    if pct exec "$CONTAINER" -- bash -c "grep -rnw /etc/apt -e unifi >/dev/null 2>&1"; then
      UNIFI="true"
      # --allow-releaseinfo-change needed because Unifi regularly changes repository metadata between versions
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get update --allow-releaseinfo-change" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    else
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get update" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    fi
    if [[ $ERROR_CODE != "" ]]; then return; fi
    # Check END
    if EFFECTIVE_HEADLESS; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}"
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    elif [[ "$UNIFI" == true ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS (Unifi) ---${CL:-}"
      # Use --force-confdef/--force-confold to suppress Unifi interactive prompts
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
    fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$(APT_FRONTEND_PREFIX)apt-get autoclean -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      EXTRAS || return $?
      TRIM_FILESYSTEM
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
    echo -e "\n${OR:-}--- DNF UPGRATE ---${CL:-}"
    RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "dnf -y upgrade" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
    RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "dnf -y autoremove" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS || return $?
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ archlinux ]]; then
    echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
    RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "$PACMAN_ENVIRONMENT pacman -Su --noconfirm" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS || return $?
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ alpine ]]; then
    echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
    RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- ash -c "apk -U upgrade" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    if [[ "$WILL_STOP" != true ]]; then echo; fi
    echo
  elif [[ "$OS" =~ centos ]]; then
    echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
    RUN_UPDATE_COMMAND pct exec "$CONTAINER" -- bash -c "yum -y update" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS || return $?
    TRIM_FILESYSTEM
    UPDATE_CHECK
  else
    echo -e "${OR:-}The system could not be idetified.${CL:-}"
    RECORD_UPDATE_RESULT "$CONTAINER" unsupported 21 || return 1
  fi
  if [[ "${UPDATE_RESULT_TARGET:-}" != "$CONTAINER" ]]; then
    RECORD_UPDATE_RESULT "$CONTAINER" success 0 || return 1
  fi
  CCONTAINER=""
}

############################
########### VM #############
############################

# VM Update Start
VM_UPDATE_START () {
  USE_INTERNAL_TARGET_SELECTION="${USE_INTERNAL_TARGET_SELECTION:-false}"
  local vm_internal_ssh_state
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  if [[ "$USE_INTERNAL_TARGET_SELECTION" == true ]] && declare -f TARGET_SELECTION_ALLOWS >/dev/null 2>&1; then
    UU_FILTER_SCOPE=update UU_FILTER_ELIGIBLE_IDS="$VMS" export UU_FILTER_SCOPE UU_FILTER_ELIGIBLE_IDS
  fi
  # Loop through the VMs
  for VM in $VMS; do
    vm_internal_ssh_state=3
    if declare -f INTERNAL_SSH_TARGET_STATE >/dev/null 2>&1; then
      if INTERNAL_SSH_TARGET_STATE vm "$VM"; then
        vm_internal_ssh_state=0
      else
        vm_internal_ssh_state=$?
      fi
    fi
    if [[ "$SINGLE_UPDATE" == true && "$VM" != "$ONLY" ]]; then
      continue
    elif [[ "$SINGLE_UPDATE" != true && "$USE_INTERNAL_TARGET_SELECTION" == true ]] && ! TARGET_SELECTION_ALLOWS update "$VM" "$VMS"; then
      echo -e "⏩${BL:-} Skipped VM $VM by internal target selection${CL:-}\n\n"
    elif [[ "$SINGLE_UPDATE" != true ]] && guest_id_matches "$EXCLUDED" "$VM"; then
      echo -e "⏩${BL:-} Skipped VM $VM by update filter (excluded)${CL:-}\n\n"
    elif [[ "$SINGLE_UPDATE" != true && "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$VM"; then
      echo -e "⏩${BL:-} Skipped VM $VM by update filter (not selected)${CL:-}\n\n"
    elif (qm config "$VM" | grep template >/dev/null 2>&1); then
      echo -e "⏩${BL:-} ${OR:-}VM $VM is a template - skip update${CL:-}\n\n"
      continue
    elif ! QGA_CONFIG_ENABLED "$VM" &&
      ! { [[ "$vm_internal_ssh_state" -ne 1 ]] && [[ -f $LOCAL_FILES/VMs/$VM || "$vm_internal_ssh_state" -eq 0 || "$vm_internal_ssh_state" -eq 2 ]]; }; then
      echo -e "⏩${BL:-} Skipped VM $VM because, QEMU or enabled Internal SSH hasn't initialized${CL:-}\n\n"
      continue
    else
      if [[ "${UU_API_ACTION:-}" == update ]] &&
        declare -f API_UPDATE_TARGET_IDENTITY_GUARD >/dev/null 2>&1 &&
        ! API_UPDATE_TARGET_IDENTITY_GUARD "$VM" vm; then
        UPDATE_FAILURE=true
        continue
      fi
      STATUS=$(qm status "$VM")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
        # Check if update is possible
        if QGA_CONFIG_ENABLED "$VM" ||
          { [[ "$vm_internal_ssh_state" -ne 1 ]] && [[ -f $LOCAL_FILES/VMs/$VM || "$vm_internal_ssh_state" -eq 0 || "$vm_internal_ssh_state" -eq 2 ]]; }; then
          if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
            UPDATE_TARGET_CAPABILITY_GUARD "$VM" vm
            capability_rc=$?
            [[ "$capability_rc" -eq 0 ]] || { [[ "$capability_rc" -eq 21 ]] || UPDATE_FAILURE=true; continue; }
          fi
          if [[ "${UU_API_ACTION:-}" == update ]]; then
            local api_os_hint
            api_os_hint=$(qm config "$VM" 2>/dev/null | awk -F': ' '$1 == "ostype" {print $2; exit}')
            NAME="VM $VM"
            if ! API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH "$VM" vm "$api_os_hint" true; then
              UPDATE_FAILURE=true
              continue
            fi
          fi
          if ! REQUIRE_PACKAGE_DATA_INVALIDATION ||
            ! MARK_PACKAGE_DATA_INVALIDATED "$VM" vm; then
            UPDATE_FAILURE=true
            continue
          fi
          # Start the VM
          WILL_STOP="true"
          echo -e " ▶${GN:-} Starting VM${BL:-} $VM ${CL:-}"
          RUN_PROXMOX_COMMAND qm start "$VM"
          START_WAITING="true"
          SINGLE_TARGET_EXECUTED=true
          if declare -F CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE >/dev/null 2>&1 &&
            ! CAPTURE_STARTED_GUEST_UPDATE_PENDING_BEFORE "$VM" vm; then
            ERROR_CODE=96
            ID=$VM
            NAME="VM $VM"
            ERROR_MSG="PENDING_BEFORE_UNAVAILABLE: fresh package baseline could not be collected after starting VM $VM"
            RECORD_UPDATE_RESULT "$VM" failed 96 || true
            ERROR
          else
            UPDATE_VM "$VM"
          fi
          MARK_PACKAGE_DATA_MUTATION_COMPLETE "$VM" vm || UPDATE_FAILURE=true
          CAPTURE_POST_UPDATE_STATUS "$VM" cvm
          CVM=""
          # Stop the VM
          echo -e "⏹ ${GN:-} Shutting down VM${BL:-} $VM ${CL:-}\n\n"
          if declare -F RESTORE_STOPPED_VM >/dev/null 2>&1; then
            if ! RESTORE_STOPPED_VM "$VM"; then
              UPDATE_FAILURE=true
              ERROR_CODE=1
              ID=$VM
              NAME="VM $VM"
              ERROR_MSG="VM $VM did not return to stopped state after update"
              ERROR
            fi
          else
            RUN_PROXMOX_COMMAND qm shutdown "$VM" &
          fi
          WILL_STOP="false"
          START_WAITING="false"
        else
          echo -e "⏩${BL:-} Skipped VM $VM because, QEMU or SSH hasn't initialized${CL:-}\n\n"
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM because stopped VMs are disabled${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
        if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
          UPDATE_TARGET_CAPABILITY_GUARD "$VM" vm
          capability_rc=$?
          [[ "$capability_rc" -eq 0 ]] || { [[ "$capability_rc" -eq 21 ]] || UPDATE_FAILURE=true; continue; }
        fi
        SINGLE_TARGET_EXECUTED=true
        UPDATE_VM "$VM"
        MARK_PACKAGE_DATA_MUTATION_COMPLETE "$VM" vm || UPDATE_FAILURE=true
        CAPTURE_POST_UPDATE_STATUS "$VM" cvm
        AUTO_REBOOT_GUEST vm "$VM" false || UPDATE_FAILURE=true
        CVM=""
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM because running VMs are disabled${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# Detect the Proxmox guest OS without contacting the guest.  This guard is
# deliberately used before snapshot/backup so a disabled Windows install has
# no protection side effects.
VM_IS_WINDOWS() {
  local vmid="$1" ostype
  ostype=$(qm config "$vmid" 2>/dev/null | awk -F': ' '$1 == "ostype" {print tolower($2); exit}')
  [[ "$ostype" =~ ^win ]]
}

# VM Update
# shellcheck disable=SC2015
UPDATE_VM () {
  local ssh_profile_configured=false internal_ssh_state=3 api_os_hint=""
  VM=$1
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  CVM="true"
  echo 'VM="'"$VM"'"' > "$TEMP_STATE_DIR/var"
  echo -e "🔄${GN:-} Updating VM ${BL:-}$VM${CL:-} : ${GN:-}$NAME${CL:-}\n"
  if declare -f CAPTURE_UPDATE_PENDING_BEFORE >/dev/null 2>&1; then
    CAPTURE_UPDATE_PENDING_BEFORE "$VM"
  fi
  if declare -f UPDATE_TARGET_CAPABILITY_GUARD >/dev/null 2>&1; then
    UPDATE_TARGET_CAPABILITY_GUARD "$VM" vm
    local capability_rc=$?
    [[ "$capability_rc" -eq 0 ]] || { CVM=""; return "$capability_rc"; }
  fi
  if [[ "${UU_API_ACTION:-}" == update ]]; then
    api_os_hint=$(qm guest cmd "$VM" get-osinfo 2>/dev/null || true)
    [[ -n "$api_os_hint" ]] || api_os_hint=$(qm config "$VM" 2>/dev/null | awk -F': ' '$1 == "ostype" {print $2; exit}')
    API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH "$VM" vm "$api_os_hint" || { CVM=""; return $?; }
  fi
  if VM_IS_WINDOWS "$VM" && [[ "$WINDOWS_UPDATE_ENABLED" != true ]]; then
    echo -e "⏩${YL:-} Windows update installation skipped for VM $VM: WINDOWS_UPDATE_ENABLED=false${CL:-}\n"
    if declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$VM" skipped 0 || true
    fi
    UPDATE_WARNING=true
    UPDATE_RESULT_RECORDED=true
    UPDATE_RESULT_TARGET="$VM"
    CVM=""
    return 0
  fi
  REQUIRE_PACKAGE_DATA_INVALIDATION || return 1
  MARK_PACKAGE_DATA_INVALIDATED "$VM" vm || return $?
  # Backup
  echo -e "💾${OR:-} Start Snapshot and/or Backup${CL:-}"
  if ! VM_BACKUP; then
    SAFETY_FAILURE=true
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Configured snapshot/backup protection failed; VM update aborted"
    ERROR
    return 1
  fi
  echo
  if SCRIPT_ONLY_ENABLED "$VM"; then
    SCRIPT_ONLY_VM || {
      ERROR_CODE=$?
      ID=$VM
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    CVM=""
    return
  fi
  # Resolve Internal SSH independently of the legacy VM profile.  The WebUI
  # configuration is the preferred source, while legacy VM files remain a
  # compatible fallback for guests without an Internal SSH entry.
  if [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
    ssh_profile_configured=true
    IP=$(awk -F'"' '/^IP=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-45}"
  fi
  if declare -f INTERNAL_SSH_TARGET_STATE >/dev/null 2>&1; then
    if INTERNAL_SSH_TARGET_STATE vm "$VM"; then
      internal_ssh_state=0
    else
      internal_ssh_state=$?
    fi
    case "$internal_ssh_state" in
      0) ssh_profile_configured=true ;;
      1) ssh_profile_configured=false ;;
      2)
        echo -e "${RD:-}  ❌ Invalid Internal SSH configuration for VM $VM: ${INTERNAL_SSH_ERROR:-unable to parse configuration}${CL:-}" >&2
        ERROR_CODE=2
        ID=$VM
        ERROR_MSG="Invalid Internal SSH configuration for VM $VM: ${INTERNAL_SSH_ERROR:-unable to parse configuration}"
        ERROR
        return 2
        ;;
    esac
  fi
  if [[ "$ssh_profile_configured" == true ]]; then
    if ! INTERNAL_SSH_RESOLVE_VM "$VM" "${IP:-}" "${USER:-root}" "${SSH_VM_PORT:-22}"; then
      echo -e "${RD:-}  ❌ Could not resolve SSH configuration for VM $VM: ${INTERNAL_SSH_ERROR:-unknown error}${CL:-}" >&2
      ERROR_CODE=2
      ID=$VM
      ERROR_MSG="Could not resolve SSH configuration for VM $VM: ${INTERNAL_SSH_ERROR:-unknown error}"
      ERROR
      return 2
    fi
    if [[ "${INTERNAL_SSH_ENABLED:-true}" != true ]]; then
      UPDATE_VM_QEMU
      return $?
    fi
    IP="${INTERNAL_SSH_HOST:-${IP:-}}"; USER="${INTERNAL_SSH_USER:-${USER:-root}}"; SSH_VM_PORT="${INTERNAL_SSH_PORT:-${SSH_VM_PORT:-22}}"; INTERNAL_SSH_USE_IDENTITY
    if [[ "$START_WAITING" == true ]]; then
      echo -e "⏳${OR:-} Wait for bootup${CL:-}"
      echo -e "ℹ ${OR:-} $SSH_START_DELAY_TIME seconds is set for sleep between tryouts in SSH-VM config file${CL:-}\n"
      if ! WAIT_FOR_BOOTUP_SSH; then
        START_WAITING=false
        UPDATE_VM_QEMU
        return
      fi
    fi
    if ! RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" exit >/dev/null 2>&1; then
      echo -e "${RD:-}  ❌ File for ssh connection found, but not correctly set?\n\
  ${BL:-}Please check SSH Key-Based Authentication${CL:-}\n\
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/${INSTALLED_BRANCH:-master}/ssh.md>
  Try to use QEMU insead\n"
      START_WAITING=false
      UPDATE_VM_QEMU
    else
      # Run the selected VM transport for the complete operation.  Windows
      # uses its existing PowerShell/WUA commands through OpenSSH; QGA is only
      # selected above when the bounded SSH probe was unavailable.
      SSH_CONNECTION="true"
      if VM_IS_WINDOWS "$VM"; then
        UPDATE_VM_SSH_WINDOWS
        local windows_rc=$?
        if [[ "$windows_rc" -eq 0 ]]; then
          UPDATE_RESULT_RECORDED=true
          UPDATE_RESULT_TARGET="$VM"
          [[ "${UPDATE_PENDING_BEFORE[$VM]-}" == 0 ]] && UPDATE_WARNING=true
        fi
        CVM=""
        return "$windows_rc"
      fi
      SSH_UNAME=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" uname -s 2>/dev/null || true)
      SSH_UNAME_VERSION=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" uname -v 2>/dev/null || true)
      OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" hostnamectl 2>/dev/null | grep System || true)
      # Free-BSD
      if [[ ("$SSH_UNAME" == FreeBSD || "$SSH_UNAME_VERSION" =~ FreeBSD) && $FREEBSD_UPDATES == true ]]; then
        echo -e "${OR:-}--- PKG UPDATE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg update || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG UPGRADE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg upgrade -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG CLEANING ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg autoremove -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo
        RECORD_UPDATE_RESULT "$VM" success 0 || return 1
        return
      elif [[ "$SSH_UNAME" == FreeBSD || "$SSH_UNAME_VERSION" =~ FreeBSD ]]; then
        echo -e "${OR:-} Free BSD skipped by user${CL:-}\n"
        RECORD_UPDATE_RESULT "$VM" skipped 0 || return 1
        return
      # Debian Base
      elif [[ "${OS,,}" =~ debian|ubuntu|mint|kali|neon|devuan ]]; then
        # Check Internet connection
        if ! ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$CHECK_URL_EXE" -c1 "$CHECK_URL" &>/dev/null; then
          echo -e "${OR:-} ❌ Internet check fail - skip this VM${CL:-}\n"
          UPDATE_FAILURE=true
          return
        fi
        if [[ "$USER" != root ]]; then
          UPDATE_USER="sudo "
        fi
        if ! DPKG_REPAIR_PREPARE "vm:$VM" "VM $VM via SSH" DPKG_REPAIR_RUN_SSH "$IP" "$SSH_VM_PORT" "$USER"; then
          ERROR_CODE=1
          ID=$VM
          ERROR_MSG="${DPKG_REPAIR_ERROR:-DPKG_REPAIR_FAILED}"
          ERROR
          return
        fi
        local apt_prefix="$UPDATE_USER"
        if EFFECTIVE_HEADLESS; then
          if [[ -n "$UPDATE_USER" ]]; then
            apt_prefix="${UPDATE_USER}env DEBIAN_FRONTEND=noninteractive "
          else
            apt_prefix="env DEBIAN_FRONTEND=noninteractive "
          fi
        fi
        echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "${apt_prefix}apt-get update -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
        if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
          RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" "${apt_prefix}apt-get ${DPKG_OPTIONS_STRING} upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
          if [[ $ERROR_CODE != "" ]]; then return; fi
        else
          RUN_UPDATE_COMMAND ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "${apt_prefix}apt-get ${DPKG_OPTIONS_STRING} -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
          if [[ $ERROR_CODE != "" ]]; then return; fi
        fi
        echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "${apt_prefix}apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        RUN_UPDATE_COMMAND ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "${apt_prefix}apt-get autoclean -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS || return $?
        UPDATE_CHECK
      # Fedora
      elif [[ "$OS" =~ Fedora ]]; then
        echo -e "\n${OR:-}--- DNF UPGRADE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y upgrade || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS || return $?
        UPDATE_CHECK
      # Arch
      elif [[ "$OS" =~ Arch ]]; then
        echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pacman -Su --noconfirm || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS || return $?
        UPDATE_CHECK
      # Alpine
      elif [[ "$OS" =~ Alpine ]]; then
        echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" apk -U upgrade || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      # Cent OS
      elif [[ "$OS" =~ CentOS ]]; then
        echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
        RUN_UPDATE_COMMAND ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" yum -y update || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$UPDATE_STEP_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS || return $?
        UPDATE_CHECK
      # Windows ( WindowsUpdate need admin rights, ...)
#      elif [[ $OS_BASE == "win10" || $OS_BASE == "win11" ]]; then
#        # check updates
#        ssh -p "$SSH_VM_PORT" "$USER@$IP" "powershell.exe -Command Get-WindowsUpdate"
#        # install updates
#        ssh -p "$SSH_VM_PORT" "$USER@$IP" "powershell.exe -Command Install-WindowsUpdate -AcceptAll -IgnoreReboot"
      else
        echo -e "${RD:-}  ❌ The system is not supported.\n  Maybe with later version ;)\n${CL:-}"
        echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
        RECORD_UPDATE_RESULT "$VM" unsupported 21 || return 1
      fi
      return
    fi
  else
    UPDATE_VM_QEMU
  fi
}

# Reuse the same Windows PowerShell/WUA lifecycle for both transports.  The
# transport is selected before mutation and is not changed if a selected SSH
# command later fails.
UPDATE_VM_SSH_WINDOWS () {
  WINDOWS_UPDATE_TRANSPORT=ssh
  WINDOWS_UPDATE_SSH_HOST="$IP"
  WINDOWS_UPDATE_SSH_PORT="$SSH_VM_PORT"
  WINDOWS_UPDATE_SSH_USER="$USER"
  UPDATE_VM_QEMU_WINDOWS
  local windows_rc=$?
  unset WINDOWS_UPDATE_TRANSPORT WINDOWS_UPDATE_SSH_HOST WINDOWS_UPDATE_SSH_PORT WINDOWS_UPDATE_SSH_USER
  return "$windows_rc"
}

# QEMU
# shellcheck disable=SC2015
UPDATE_VM_QEMU () {
  local qga_ready=false
  echo -e " ▶${GN:-} Try to connect via QEMU${CL:-}"
  QGA_ERROR=""
  if WAIT_FOR_QGA; then
    qga_ready=true
    KERNEL=$(qm guest cmd "$VM" get-osinfo | grep kernel-version || true)
    OS=$(qm guest cmd "$VM" get-osinfo | grep name || true)
    if [[ "${OS,,}" =~ windows ]]; then
      UPDATE_VM_QEMU_WINDOWS
      local windows_status=$?
      CVM=""
      return "$windows_status"
    fi
  fi
  if [[ "$qga_ready" == true ]] && CHECK_QGA_EXEC; then
    echo -e "${OR:-}  QEMU Guest Agent is available.${CL:-}\n"
    # Run Update
    if [[ $KERNEL =~ FreeBSD && $FREEBSD_UPDATES == true ]]; then
      echo -e "${OR:-}--- PKG UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- tcsh -c "pkg update" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- PKG UPGRADE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- tcsh -c "pkg upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- PKG CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- tcsh -c "pkg autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
      return
    elif [[ "$KERNEL" =~ FreeBSD ]]; then
      echo -e "${OR:-} Free BSD skipped by user${CL:-}\n"
      RECORD_UPDATE_RESULT "$VM" skipped 0 || return 1
      return
    elif [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      # Check Internet connection
      if ! (RUN_QEMU_COMMAND "$VM" -- bash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"); then
        echo -e "${OR:-} ❌ Internet is not reachable - skip the update${CL:-}\n"
        return
      fi
      if ! DPKG_REPAIR_PREPARE "vm:$VM" "VM $VM via QEMU Guest Agent" DPKG_REPAIR_RUN_QGA "$VM"; then
        ERROR_CODE=1
        ID=$VM
        ERROR_MSG="${DPKG_REPAIR_ERROR:-DPKG_REPAIR_FAILED}"
        ERROR
        return
      fi
      echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" --timeout 120 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        RUN_QEMU_DURABLE "$VM" --timeout 120 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        RUN_QEMU_DURABLE "$VM" --timeout 120 -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RUN_QEMU_COMMAND "$VM" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get autoclean -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Fedora ]]; then
      echo -e "\n${OR:-}--- DNF UPGRADE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "dnf -y upgrade" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "dnf -y --purge autoremove" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Arch ]]; then
      echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "pacman -Su --noconfirm" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "$OS" =~ Alpine ]]; then
      echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- ash -c "apk -U upgrade" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RECORD_UPDATE_RESULT "$VM" success 0 || return 1
    elif [[ "$OS" =~ CentOS ]]; then
      echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "yum -y update" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo
      UPDATE_CHECK
    elif [[ "${OS,,}" =~ windows ]]; then
      UPDATE_VM_QEMU_WINDOWS
    else
      echo -e "${RD:-}  The system is not supported.\n  Maybe with later version ;)\n${CL:-}"
      echo -e "  If you want, make a request here: <https://github.com/BassT23/Proxmox/issues>\n"
      RECORD_UPDATE_RESULT "$VM" unsupported 21 || return 1
    fi
  else
    echo -e "${RD:-}  ❌ ${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}${CL:-}\n\
  ${OR:-}If you want to update VMs, you must set up it by yourself!${CL:-}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/${INSTALLED_BRANCH:-master}/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}"
    ERROR
  fi
  CVM=""
}

UPDATE_VM_QEMU_WINDOWS () {
  local encoded result marker update_status processed reboot message preflight_status preflight_reason
  local job_id start_state start_job status_phase status_result status_message status_result_code deadline
  local status_read_retries=0
  local windows_transport="${WINDOWS_UPDATE_TRANSPORT:-qga}"

  WINDOWS_UPDATE_EXEC() {
    local mode="$1" output rc=0
    shift
    if [[ "$windows_transport" != ssh ]]; then
      if [[ "$mode" == readonly ]]; then
        QEMU_GUEST_EXEC_READONLY "$@"
      else
        QEMU_GUEST_EXEC "$@"
      fi
      return
    fi
    shift
    while (($# > 0)) && [[ "$1" != -- ]]; do shift; done
    [[ "${1:-}" == -- ]] && shift
    output=$(UU_SSH_COMMAND_TIMEOUT=30 RUN_SSH_COMMAND \
      "$WINDOWS_UPDATE_SSH_HOST" "$WINDOWS_UPDATE_SSH_PORT" "$WINDOWS_UPDATE_SSH_USER" "$@" 2>&1) || rc=$?
    QEMU_EXEC_STDOUT="$output"
    QEMU_EXEC_STDERR=""
    QEMU_EXEC_OUTPUT="$output"
    QEMU_EXEC_EXITCODE="$rc"
    QEMU_EXEC_TRANSPORT_RC=0
    QEMU_EXEC_ERROR_CLASS=SSH_GUEST_EXEC
    if [[ "$rc" == 124 || "$rc" == 255 ]]; then
      QEMU_EXEC_TRANSPORT_RC=1
      QEMU_EXEC_EXITCODE=0
      [[ "$rc" == 124 ]] && QEMU_EXEC_ERROR_CLASS=SSH_TIMEOUT || QEMU_EXEC_ERROR_CLASS=SSH_CONNECTION_FAILED
    fi
  }

  if ! declare -f WINDOWS_POWERSHELL_ENCODE >/dev/null 2>&1; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Windows update helper is not installed"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  if [[ "${WINDOWS_UPDATE_STATUS_ONLY:-false}" == true ]]; then
    job_id="$UU_WINDOWS_STATUS_ONLY_JOB_ID"
    # Recovery is status-only: reuse the already confirmed guest job and
    # never enter the mutating install-start path.
    start_job="$job_id"
  else
  if ! encoded=$(WINDOWS_POWERSHELL_ENCODE preflight); then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Could not encode the Windows Update preflight command"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi
  WINDOWS_UPDATE_EXEC readonly "$VM" --timeout 30 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  if [[ "$QEMU_EXEC_TRANSPORT_RC" -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    ERROR_CODE=${QEMU_EXEC_EXITCODE:-1}
    ID=$VM
    ERROR_MSG="${QEMU_EXEC_OUTPUT:-Windows Update preflight failed}"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi
  result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" |
    tr -d '\r' | sed -n '/^UU_WINDOWS|preflight|/p' | tail -n 1)
  IFS='|' read -r marker preflight_status preflight_reason message <<< "$result"
  if [[ "$marker" != UU_WINDOWS || "$preflight_status" != preflight || "$preflight_reason" != ok ]]; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Windows Update preflight blocked: ${message:-unknown reason}"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  job_id="uu-${VM}-$(date -u '+%Y%m%d%H%M%S')-$$-${RANDOM}"
  if ! encoded=$(WINDOWS_POWERSHELL_ENCODE install-start "$job_id"); then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Could not encode the Windows Update PowerShell command"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  echo -e "${OR:-}--- WINDOWS UPDATE ---${CL:-}"
  WINDOWS_UPDATE_EXEC mutating "$VM" --timeout 30 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  if [[ "$QEMU_EXEC_TRANSPORT_RC" -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    ERROR_CODE=${QEMU_EXEC_EXITCODE:-1}
    ID=$VM
    ERROR_MSG="${QEMU_EXEC_OUTPUT:-Windows Update command failed}"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" | tr -d '\r' | sed -n '/^UU_WINDOWS|start|/p' | tail -n 1)
  IFS='|' read -r marker update_status start_state start_job message <<< "$result"
  if [[ "$marker" != UU_WINDOWS || "$update_status" != start ||
    ("$start_state" != started && "$start_state" != existing && "$start_state" != existing-active) ||
    ("$start_state" != existing-active && "$start_job" != "$job_id") ||
    ! "$start_job" =~ ^[A-Za-z0-9._-]+$ ]]; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Invalid Windows Update start response: $result"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi
  fi

  # Only short status reads use the selected transport.  A transport timeout leaves the
  # guest job and its durable state untouched; never issue taskkill or start
  # another mutating command as a reaction to it.
  deadline=$((SECONDS + ${UU_WINDOWS_UPDATE_STATUS_TIMEOUT:-900}))
  while :; do
    if ! encoded=$(WINDOWS_POWERSHELL_ENCODE install-status "$start_job"); then
      ERROR_CODE=1; ID=$VM; ERROR_MSG="Could not encode Windows Update status command"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
      ERROR; return
    fi
    WINDOWS_UPDATE_EXEC readonly "$VM" --timeout 30 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
    if [[ "$QEMU_EXEC_TRANSPORT_RC" -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
      if [[ "$windows_transport" == qga && "$QEMU_EXEC_ERROR_CLASS" == QGA_TRANSIENT && "$status_read_retries" -lt 2 ]]; then
        status_read_retries=$((status_read_retries + 1))
        sleep "$status_read_retries"
        continue
      fi
      ERROR_CODE=1; ID=$VM
      ERROR_MSG="Windows Update status is unknown after QGA communication failure: ${QEMU_EXEC_OUTPUT:-unknown}"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
      ERROR; return
    fi
    status_read_retries=0
    result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" | tr -d '\r' | sed -n '/^UU_WINDOWS|status|/p' | tail -n 1)
    IFS='|' read -r marker update_status start_job status_phase processed reboot status_result status_message status_result_code <<< "$result"
    if [[ "$marker" != UU_WINDOWS || "$update_status" != status || "$start_job" != "$job_id" ||
      ! "$processed" =~ ^[0-9]+$ || ("$reboot" != true && "$reboot" != false) ]]; then
      ERROR_CODE=1; ID=$VM; ERROR_MSG="Invalid Windows Update status response: $result"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
      ERROR; return
    fi
    if [[ -n "$status_result_code" && "$status_result_code" != null && ! "$status_result_code" =~ ^-?[0-9]+$ ]]; then
      ERROR_CODE=1; ID=$VM; ERROR_MSG="Invalid Windows Update result code: $result"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
      ERROR; return
    fi
    if [[ "$status_phase" == completed ]]; then
      if [[ "$status_result" != ok ]]; then
        ERROR_CODE=1; ID=$VM; ERROR_MSG="Windows Update failed: ${status_message:-unknown}"
        declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" "$status_result_code" "$reboot" "$processed" || true
        ERROR; return
      fi
      echo "Windows updates processed: $processed"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" success 0 "$status_result_code" "$reboot" "$processed" || true
      [[ "$reboot" == true ]] && echo -e "${OR:-}Reboot required; no automatic reboot was performed.${CL:-}"
      return
    fi
    if [[ "$status_phase" == failed || "$status_phase" == unknown ]]; then
      ERROR_CODE=1; ID=$VM; ERROR_MSG="Windows Update state is ${status_phase}: ${status_message:-unknown}"
      declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
      ERROR; return
    fi
    if [[ "$deadline" -gt 0 && "$SECONDS" -ge "$deadline" ]]; then
      # The controller deadline is not a guest-job deadline. Preserve the
      # guest job identity for a later read-only recovery and let job-runner
      # publish an unresolved state instead of a false installation failure.
      local unresolved_dir unresolved_file
      unresolved_dir="${UU_REMOTE_WORK_DIR:-${LOCAL_FILES:-/etc/ultimate-updater}/temp}"
      unresolved_file="$unresolved_dir/windows-update-unresolved"
      mkdir -p -- "$unresolved_dir" 2>/dev/null || true
      {
        printf 'job_id=%s\n' "$job_id"
        printf 'target=%s\n' "$VM"
        printf 'reason=controller-timeout\n'
        printf 'recorded_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
      } > "${unresolved_file}.tmp.$$" 2>/dev/null &&
        mv -f -- "${unresolved_file}.tmp.$$" "$unresolved_file" 2>/dev/null || true
      WINDOWS_UPDATE_UNRESOLVED=true
      ERROR_CODE=75; ID=$VM; ERROR_MSG="Windows Update controller timeout; guest job $job_id remains unresolved"
      ERROR; return "$ERROR_CODE"
    fi
    sleep 2
  done
}

## General ##
if ! READ_CONFIG; then
  exit 1
fi

# Debug
DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' $CONFIG_FILE)
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Logging
OUTPUT_TO_FILE () {
  echo 'EXEC_HOST="'"$HOSTNAME"'"' > "$TEMP_STATE_DIR/exec_host"
  if [[ "$RICM" != true ]]; then
    touch "$LOG_FILE"
    exec &> >(tee "$LOG_FILE")
  fi
  # Welcome-Screen
  if [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
    WELCOME_SCREEN=true
    if [[ "$RICM" != true ]]; then
      touch $LOCAL_FILES/check-output
    fi
  fi
}
# shellcheck disable=SC2329
CLEAN_LOGFILE () {
  if [[ "$RICM" != true ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
        cat "$LOG_FILE" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE" >/dev/null 2>&1
    chmod 640 "$LOG_FILE"
    if [[ -f ./tmp.log ]]; then
      rm -rf ./tmp.log
    fi
  fi
}

# Error handling
ERROR () {
  UPDATE_FAILURE=true
  if [[ "${WINDOWS_UPDATE_UNRESOLVED:-false}" != true &&
    "${CCONTAINER:-}" == true && "${ID:-}" =~ ^[0-9]+$ ]] &&
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
    STATUS_MODEL_UPDATE_RESULT "$ID" failed "${ERROR_CODE:-1}" || true
  fi
  echo -e "$ID : $NAME" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo -e "Error code:   $ERROR_CODE" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo -e "Error output: $ERROR_MSG\n" | tee -a "$ERROR_LOG_FILE" >/dev/null 2>&1
  echo
}

UPDATE_FINAL_RC() {
  local command_rc="${1:-0}"
  local warning_rc="${UPDATE_WARNING_RC:-10}"
  if [[ "$command_rc" -ne 0 || "$UPDATE_FAILURE" == true || "$SAFETY_FAILURE" == true ]]; then
    return 1
  fi
  if [[ "${REMOTE_TARGET_DISPATCHED:-false}" != true &&
    "${UPDATE_RESULT_RECORDED:-false}" != true ]]; then
    # A missing result is not a neutral no-op.  Returning exit 10 here lets a
    # remote job runner mistake an incomplete handoff for skipped work.  Keep
    # the result fail-closed unless an explicit target result was recorded.
    UPDATE_FAILURE=true
    printf 'Update result was not recorded; refusing to classify the run as a no-op.\n' >&2
    return 1
  fi
  if [[ "${UPDATE_WARNING:-false}" == true ]]; then
    return "$warning_rc"
  fi
  return 0
}

ERROR_LOGGING () {
  touch "$ERROR_LOG_FILE"
  true > "$ERROR_LOG_FILE"
}

# shellcheck disable=SC2329
UPDATE_MAIL_BODY() {
  if [[ "${SINGLE_UPDATE:-false}" != true && -f "$LOCAL_FILES/status.json" ]] &&
    declare -f STATUS_MODEL_RENDER_NOTIFICATION >/dev/null 2>&1; then
    local status_notification status_body
    if status_notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$LOCAL_FILES/status.json" update "" "" "$UPDATE_RUN_STARTED_AT" 2>/dev/null) &&
      [[ "$status_notification" == STATE=* ]]; then
      status_body=${status_notification#*$'\n'}
      printf '%s\n' "$status_body"
      return 0
    fi
  fi
  local warning_rc="${UPDATE_WARNING_RC:-10}"
  local target="${ID:-${CONTAINER:-${VM:-$HOSTNAME}}}"
  local display_name="${NAME:-$target}" target_type="host" icon="🐧" package_count
  if [[ "${CVM:-}" == true || "${VM:-}" =~ ^[0-9]+$ ]]; then
    target_type="vm"
  elif [[ "${CCONTAINER:-}" == true || "${CONTAINER:-}" =~ ^[0-9]+$ || "${ID:-}" =~ ^[0-9]+$ ]]; then
    target_type="lxc"
  fi
  package_count=$(grep -Eo '[0-9]+ (upgraded|updated|processed)' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)
  printf 'Ultimate Updater update summary\n\n'
  printf '🖥️ %s\n\n' "$HOSTNAME"
  if [[ "$target_type" != host && ! ( "$target" == "$HOSTNAME" && "$display_name" == "$HOSTNAME" ) ]]; then
    [[ "$display_name" == "$target" ]] && display_name=""
    if [[ -n "$display_name" ]]; then
      printf '%s %s · %s\n' "$icon" "$target" "$display_name"
    else
      printf '%s %s\n' "$icon" "$target"
    fi
  fi
  if [[ "${EXIT_CODE:-1}" -eq 0 && ! -s "$ERROR_LOG_FILE" ]]; then
    printf '✅ Update successful\n'
    [[ -n "$package_count" ]] && printf '⬆️ %s\n' "$package_count"
  elif [[ "${EXIT_CODE:-1}" -eq "$warning_rc" && ! -s "$ERROR_LOG_FILE" ]]; then
    printf '⚠️ Update completed with warnings\n'
    printf 'No confirmed package mutation was recorded for every selected target.\n'
  else
    printf '⚠️ Update failed\n'
    printf 'Exitcode: %s\n' "${EXIT_CODE:-1}"
    [[ -s "$ERROR_LOG_FILE" ]] && sed -n '1,4p' "$ERROR_LOG_FILE"
  fi
  if grep -Eqi 'reboot required|reboot needed' "$LOG_FILE" 2>/dev/null; then
    printf '🔄 Reboot required\n'
  fi
}

if [[ $EXIT_ON_ERROR == false ]]; then
  ERROR_LOGGING
else
  set -e
fi

# Exit
# shellcheck disable=SC2329
EXIT () {
  EXIT_CODE=$?
  local warning_rc="${UPDATE_WARNING_RC:-10}"
  if declare -f CLEAR_PACKAGE_MUTATION_RESERVATIONS >/dev/null 2>&1; then
    CLEAR_PACKAGE_MUTATION_RESERVATIONS
  fi
  if [[ -f "$TEMP_STATE_DIR/exec_host" ]]; then
    EXEC_HOST=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' "$TEMP_STATE_DIR/exec_host")
  fi
  # Avoid copying check-output back to the same host. Remote cluster
  # updates are collected by the initiating node after the remote run.
  if [[ "$WELCOME_SCREEN" == true && -n "$EXEC_HOST" && "$HOSTNAME" != "$EXEC_HOST" ]]; then
    scp "$LOCAL_FILES"/check-output "$EXEC_HOST":"$LOCAL_FILES"/check-output
  fi
  if [[ "${INITIAL_INVENTORY_CLI:-false}" == true ]]; then
    rm -f -- "${TEMP_STATE_DIR:?}/var"
    rm -rf "$LOCAL_FILES"/update
    exit "$EXIT_CODE"
  fi
  # Check-only runs own their notification and final status handling.
  if [[ "${CHECK_ONLY_RUN:-false}" == true ]]; then
    :
  # Help/version and other informational commands use the shared EXIT trap
  # only for cleanup; they are not update runs and must not mark a target or
  # emit update completion/error handling.
  elif [[ "${NON_UPDATE_COMMAND:-false}" == true ]]; then
    :
  # Exit without echo
  elif [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == "$warning_rc" ]]; then
    if [[ "${SELF_UPDATE_RUN:-false}" != true &&
      "${UU_DEFER_UPDATE_MAIL:-false}" != true ]] &&
      declare -f STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION >/dev/null 2>&1; then
      STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION "$LOCAL_FILES/status.json" \
        "${UPDATE_RUN_STARTED_AT:-}" || true
    fi
    if [[ "$RICM" != true ]]; then
      echo -e "${OR:-}⚠ Finished with warnings; no confirmed package mutation was recorded.${CL:-}\n"
      CLEAN_LOGFILE
    fi
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "${SELF_UPDATE_RUN:-false}" != true &&
      "${UU_DEFER_UPDATE_MAIL:-false}" != true ]] &&
      declare -f STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION >/dev/null 2>&1; then
      STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION "$LOCAL_FILES/status.json" \
        "${UPDATE_RUN_STARTED_AT:-}" || true
    fi
    if [[ "$RICM" != true ]]; then
      if [[ -f $ERROR_LOG_FILE && -s $ERROR_LOG_FILE ]]; then
        echo -e "${OR:-}❌ Finished, with errors.${CL:-}\n"
        echo -e "Please checkout $ERROR_LOG_FILE"
        echo
        CLEAN_LOGFILE
        if [[ "${NON_UPDATE_COMMAND:-false}" != true && "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
          if declare -f STATUS_MODEL_SEND_HTML_MAIL >/dev/null 2>&1; then
            UPDATE_MAIL_BODY |
              STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater summary - $HOSTNAME" "$EMAIL_SENDER" "$EMAIL_USER" 2>/dev/null || true
          else
            UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" 2>/dev/null || true
          fi
        fi
      else
        echo -e "${GN:-}✅ Finished.${CL:-}\n"
        "$LOCAL_FILES/exit/passed.sh"
        CLEAN_LOGFILE
        if [[ "$EMAIL_ONLY_ERROR" != true ]]; then
          if [[ "${NON_UPDATE_COMMAND:-false}" != true && "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
            if declare -f STATUS_MODEL_SEND_HTML_MAIL >/dev/null 2>&1; then
              UPDATE_MAIL_BODY |
                STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater" "$EMAIL_SENDER" "$EMAIL_USER" 2>/dev/null || true
            else
              UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater" "$EMAIL_USER" 2>/dev/null || true
            fi
          fi
        fi
      fi
    fi
  else
  # Update Error
    if [[ "${SELF_UPDATE_RUN:-false}" != true &&
      "${UU_DEFER_UPDATE_MAIL:-false}" != true ]] &&
      declare -f STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION >/dev/null 2>&1; then
      STATUS_MODEL_SEND_APPRISE_UPDATE_NOTIFICATION "$LOCAL_FILES/status.json" \
        "${UPDATE_RUN_STARTED_AT:-}" || true
    fi
    if [[ "$RICM" != true ]]; then
      echo -e "${RD:-}⚠  Error during update --- Exit Code: $EXIT_CODE${CL:-}\n"
      "$LOCAL_FILES/exit/error.sh"
      CLEAN_LOGFILE
      if [[ "${NON_UPDATE_COMMAND:-false}" != true && "${SELF_UPDATE_RUN:-false}" != true && "${UU_DEFER_UPDATE_MAIL:-false}" != true ]]; then
        if declare -f STATUS_MODEL_SEND_HTML_MAIL >/dev/null 2>&1; then
          UPDATE_MAIL_BODY |
            STATUS_MODEL_SEND_HTML_MAIL "Ultimate Updater summary - $HOSTNAME" "$EMAIL_SENDER" "$EMAIL_USER" 2>/dev/null
        else
          UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" 2>/dev/null
        fi
      fi
    fi
  fi
  sleep 3
  rm -f -- "${TEMP_STATE_DIR:?}/var"
  rm -rf "$LOCAL_FILES"/update
  if [[ -f "$TEMP_STATE_DIR/exec_host" && "$HOSTNAME" != "$EXEC_HOST" ]]; then rm -rf "$LOCAL_FILES"; fi
  exit "$EXIT_CODE"
}
trap EXIT EXIT

# Check Cluster Mode
if [[ -f "/etc/corosync/corosync.conf" ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
  MODE="Cluster "
else
  MODE="  Host  "
fi

# Run
export TERM=xterm-256color
if ! [[ -d "$TEMP_STATE_DIR" ]]; then mkdir -p "$TEMP_STATE_DIR"; fi
OUTPUT_TO_FILE
IP=$(hostname -i | cut -d ' ' -f1)
ARGUMENTS "$@"
ARGUMENT_RESULT=$?
if [[ "$ARGUMENT_RESULT" -ne 0 ]]; then
  exit "$ARGUMENT_RESULT"
fi
if [[ "$REMOTE_TARGET_DISPATCHED" == true ]]; then
  exit 0
fi

# Recovery is deliberately a separate, read-only guest-state path.  It is
# used only by job-runner for an already-started Windows job and must never
# enter the normal target loop, backup flow, or install-start path.
if [[ -n "${UU_WINDOWS_STATUS_ONLY_JOB_ID:-}" ]]; then
  if [[ ! "${UU_WINDOWS_STATUS_ONLY_JOB_ID}" =~ ^[A-Za-z0-9._-]+$ ||
    ! "${UU_WINDOWS_STATUS_ONLY_VM:-}" =~ ^[0-9]+$ ]]; then
    printf 'Invalid Windows recovery identity.\n' >&2
    exit 2
  fi
  VM="$UU_WINDOWS_STATUS_ONLY_VM"
  NAME="Windows VM $VM"
  OS="Windows"
  CVM=true
  WINDOWS_UPDATE_STATUS_ONLY=true
  UPDATE_VM_QEMU_WINDOWS
  exit $?
fi

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true ]]; then
  TAG_LOG=true
  HEADER_INFO
  if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Continue after errors: enabled${CL:-}\n"; else echo -e "ℹ ${OR:-} Continue after errors: disabled${CL:-}\n"; fi
  if [[ "$MODE" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
    if [[ "$WITH_HOST" == true ]] && { [[ "${UU_UPDATE_SCOPE:-}" == host || "$USE_INTERNAL_TARGET_SELECTION" != true ]] || TARGET_SELECTION_ALLOWS update "host:$(hostname -s 2>/dev/null || hostname)" "host:$(hostname -s 2>/dev/null || hostname)"; }; then
      UPDATE_HOST_ITSELF
    else
      echo -e "⏩${BL:-} Skipped host itself by the user${CL:-}\n\n"
    fi
    if [[ "$WITH_LXC" == true ]]; then
      CONTAINER_UPDATE_START
    else
      echo -e "⏩${BL:-} Skipped all containers by the user${CL:-}\n"
    fi
    if [[ "$WITH_VM" == true ]]; then
      VM_UPDATE_START
    else
      echo -e "⏩${BL:-} Skipped all VMs by the user${CL:-}\n"
    fi
  fi
fi

if [[ "$SAFETY_FAILURE" == true ]]; then
  exit 1
fi

if [[ "$SINGLE_UPDATE" == true && "$SINGLE_TARGET_EXECUTED" != true ]]; then
  printf 'Explicit target %s was not updated; no update lifecycle was started.\n' "$ONLY" >&2
  UPDATE_FAILURE=true
fi

final_rc=0
UPDATE_FINAL_RC 0 || final_rc=$?
if [[ "$final_rc" -eq 1 ]]; then
  exit 1
fi
exit "$final_rc"
