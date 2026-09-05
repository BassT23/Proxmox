#!/bin/bash

##############
# Tag-filter #
##############

# VERSION="1.0.0"

# Proxmox VM/CT Tag & ID Expansion Helper
#
# apply_only_exclude_tags ONLY_VAR_NAME EXCLUDE_VAR_NAME
# Expands ONLY (or if empty, EXCLUDE) into a space-separated list of target IDs.
# Supports:
#   - Plain target IDs: 101 202
#   - Delimiters: commas / semicolons / pipes / spaces intermixed (e.g. 101,202;203|204)
#   - Ranges: 120-125 (inclusive)
#   - Mixed IDs + ranges + tags: 110 testing 111 200-202
#   - Uppercase user tag input (config tags assumed already lowercase)
#     Tag tokens are any token not matching ^[0-9]+$ or ^[0-9]+-[0-9]+$.
#   - OR matching across tag tokens.
#
# Behavior summary:
#   1. Tokenize ONLY if set and always tokenize EXCLUDE when present.
#   2. For each token:
#        number        -> add as target ID
#        range a-b     -> expand (a..b)
#        tag           -> collect tag for later resolution
#   3. Resolve tags to IDs (any tag match) and append, de-duplicating while
#      preserving first-seen order (input order then discovery order for tags).
#   4. Assign final space-separated list back to ONLY / EXCLUDE variable.
#   5. ONLY is activated only when an eligible target matches it. EXCLUDE is
#      applied after the positive selection in all cases.
#
# Usage examples:
#   export ONLY="backup,windows"; apply_only_exclude_tags ONLY EXCLUDE; echo "$ONLY"
#   export ONLY="101,102,105-107"; apply_only_exclude_tags ONLY EXCLUDE; echo "$ONLY"
#   export ONLY="110 testtag 111 120-121"; apply_only_exclude_tags ONLY EXCLUDE; echo "$ONLY"
#   export ONLY="" EXCLUDE="old 300-302"; apply_only_exclude_tags ONLY EXCLUDE; echo "$EXCLUDE"
#
# Notes: Always returns 0. Bash-only (arrays, process substitution). Inherits repo license.
#
# shellcheck shell=bash
# shellcheck disable=SC2155  # Command substitution in local assignment is intentional
# shellcheck disable=SC2086  # Intended word splitting for tag token arrays

guest_id_matches() {
  local requested_list=${1:-} guest_id=${2:-} id
  local -a requested_ids
  read -r -a requested_ids <<< "$requested_list"
  for id in "${requested_ids[@]}"; do
    [[ "$id" == "$guest_id" ]] && return 0
  done
  return 1
}

version_is_less() {
  local left=${1:-} right=${2:-}
  local -a left_parts right_parts
  local i max left_part right_part

  IFS=. read -r -a left_parts <<< "$left"
  IFS=. read -r -a right_parts <<< "$right"
  max=${#left_parts[@]}
  (( ${#right_parts[@]} > max )) && max=${#right_parts[@]}

  for ((i = 0; i < max; i++)); do
    left_part=${left_parts[i]:-0}
    right_part=${right_parts[i]:-0}
    [[ "$left_part" =~ ^[0-9]+$ && "$right_part" =~ ^[0-9]+$ ]] || return 1
    left_part=$((10#$left_part))
    right_part=$((10#$right_part))
    if (( left_part < right_part )); then
      return 0
    elif (( left_part > right_part )); then
      return 1
    fi
  done
  return 1
}

VERSION_CACHE_FILE=${VERSION_CACHE_FILE:-/var/cache/ultimate-updater/versions}
VERSION_CACHE_TTL=${VERSION_CACHE_TTL:-21600}

FETCH_REMOTE_VERSION() {
  local branch=$1 component=$2 max_time=${3:-10} content version headers body http_code retry_after attempt

  headers=$(mktemp "${TMPDIR:-/tmp}/ultimate-updater-version.headers.XXXXXX") || return 1
  body=$(mktemp "${TMPDIR:-/tmp}/ultimate-updater-version.body.XXXXXX") || { rm -f -- "$headers"; return 1; }
  for attempt in 1 2 3; do
    : > "$headers"
    : > "$body"
    http_code=$(curl -4 -sS -fSL --retry 0 --connect-timeout 3 --max-time "$max_time" \
      -D "$headers" -o "$body" -w '%{http_code}' \
      "https://raw.githubusercontent.com/BassT23/Proxmox/$branch/$component" 2>/dev/null) || true
    if [[ -s "$body" ]]; then
      break
    fi
    if (( attempt < 3 )); then
      printf 'Version check failed (attempt %s/3), retrying...\n' "$attempt" >&2
    fi
  done
  if [[ ! -s "$body" ]]; then
    if [[ "$http_code" == 429 ]]; then
      retry_after=$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' "$headers")
      if [[ -n "$retry_after" ]]; then
        printf 'GitHub temporarily rate-limited the version check (Retry-After: %s). Please retry later.\n' "$retry_after" >&2
      else
        printf 'GitHub temporarily rate-limited the version check. Please retry later.\n' >&2
      fi
    fi
    rm -f -- "$headers" "$body"
    return 1
  fi
  content=$(<"$body")
  rm -f -- "$headers" "$body"
  version=$(printf '%s\n' "$content" | awk -F'"' '/^VERSION=/ {print $2; exit}')
  [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  printf '%s\n' "$version"
}

UPDATE_VERSION_CACHE() {
  local master_version beta_version develop_version cache_dir temp_file

  master_version=$(FETCH_REMOTE_VERSION master update.sh 5) || return 1
  beta_version=$(FETCH_REMOTE_VERSION beta update.sh 5) || return 1
  develop_version=$(FETCH_REMOTE_VERSION develop update.sh 5) || return 1
  cache_dir=${VERSION_CACHE_FILE%/*}
  mkdir -p "$cache_dir" || return 1
  temp_file=$(mktemp "$cache_dir/.versions.XXXXXX") || return 1
  {
    printf 'TIMESTAMP="%s"\n' "$(date +%s)"
    printf 'MASTER_VERSION="%s"\n' "$master_version"
    printf 'BETA_VERSION="%s"\n' "$beta_version"
    printf 'DEVELOP_VERSION="%s"\n' "$develop_version"
  } > "$temp_file" || { rm -f -- "$temp_file"; return 1; }
  chmod 644 "$temp_file" || { rm -f -- "$temp_file"; return 1; }
  mv -f -- "$temp_file" "$VERSION_CACHE_FILE" || { rm -f -- "$temp_file"; return 1; }
}

READ_VERSION_CACHE() {
  local timestamp master_version beta_version develop_version now

  [[ -r "$VERSION_CACHE_FILE" ]] || return 1
  timestamp=$(awk -F'"' '/^TIMESTAMP=/ {print $2; exit}' "$VERSION_CACHE_FILE")
  master_version=$(awk -F'"' '/^MASTER_VERSION=/ {print $2; exit}' "$VERSION_CACHE_FILE")
  beta_version=$(awk -F'"' '/^BETA_VERSION=/ {print $2; exit}' "$VERSION_CACHE_FILE")
  develop_version=$(awk -F'"' '/^DEVELOP_VERSION=/ {print $2; exit}' "$VERSION_CACHE_FILE")
  [[ "$timestamp" =~ ^[0-9]+$ ]] || return 1
  [[ "$master_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [[ "$beta_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  [[ "$develop_version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  now=$(date +%s)
  CACHE_AGE=$((now - timestamp))
  (( CACHE_AGE < 0 )) && CACHE_AGE=0
  # These globals are consumed by welcome-screen.sh after this function returns.
  # shellcheck disable=SC2034
  CACHE_MASTER_VERSION=$master_version
  # shellcheck disable=SC2034
  CACHE_BETA_VERSION=$beta_version
  # shellcheck disable=SC2034
  CACHE_DEVELOP_VERSION=$develop_version
  if (( CACHE_AGE <= VERSION_CACHE_TTL )); then
    # shellcheck disable=SC2034
    CACHE_FRESH=true
  else
    # shellcheck disable=SC2034
    CACHE_FRESH=false
  fi
  return 0
}

# Store the last processed message; caller prints when desired.
_record_tag_log() { TAG_FILTER_LAST_LOG+="$*"; }
print_tag_log() { [[ -n ${TAG_FILTER_LAST_LOG:-} ]] && printf "%b" "$TAG_FILTER_LAST_LOG"; }

apply_only_exclude_tags() {
  local _only_var_name=$1 _exclude_var_name=$2

  # Validate arguments: both variable names must be provided.
  [[ -z $_only_var_name || -z $_exclude_var_name ]] && return 0

  # Indirect expansion: read caller-provided variables.
  local _ONLY_VALUE="${!_only_var_name}" _EXCLUDE_VALUE="${!_exclude_var_name}"
  [[ -z $_ONLY_VALUE && -z $_EXCLUDE_VALUE ]] && return 0

  # ------------------------------------------------------------------------
  # Helper: gather all relevant Proxmox config files (unique list)
  # ------------------------------------------------------------------------
  _gather_conf_files() {
    local f d nd
    # Top-level qemu + lxc
    for d in /etc/pve/qemu-server /etc/pve/lxc; do
      [[ -d $d ]] || continue
      for f in "$d"/*.conf; do [[ -f $f ]] && echo "$f"; done
    done
    # Per-node directories
    for nd in /etc/pve/nodes/*; do
      [[ -d $nd ]] || continue
      for d in "$nd"/qemu-server "$nd"/lxc; do
        [[ -d $d ]] || continue
        for f in "$d"/*.conf; do [[ -f $f ]] && echo "$f"; done
      done
    done | sort -u
  }

  # ------------------------------------------------------------------------
  # Helper: Build "tag map" lines: <vmid> <tag1> <tag2> ...
  # Each tag list is normalized to lowercase and tokens separated by single spaces.
  # ------------------------------------------------------------------------
  _build_tag_map() {
    local f id tline tags norm
    while read -r f; do
      [[ -f $f ]] || continue
      id="$(basename "$f" .conf)"; [[ $id =~ ^[0-9]+$ ]] || continue
      # Capture the first tags line (if any)
      tline=$(grep -i '^tags:' "$f" 2>/dev/null | head -n1 || true)
      [[ -n $tline ]] || continue
      tags=${tline#*:}
      # Lowercase + translate ; , | to spaces
      tags=$(echo "$tags" | tr '[:upper:];,|' '[:lower:]   ')
      # Normalize collapse whitespace & ensure trailing space separation for matching
      norm=$(echo "$tags" | xargs -n1 echo 2>/dev/null | tr '\n' ' ')
      echo "$id $norm"
    done < <(_gather_conf_files)
  }

  # ------------------------------------------------------------------------
  # Helper: Resolve a list of tag tokens -> space separated unique numeric IDs
  # ------------------------------------------------------------------------
  _resolve_ids_for_tags() {
    local tag_arr=() tok
    for tok in "$@"; do
      [[ -n $tok ]] || continue
      # Lowercase per comparison logic
      tag_arr+=("$(echo "$tok" | tr '[:upper:]' '[:lower:]')")
    done
    [[ ${#tag_arr[@]} -gt 0 ]] || return 0

    local matched=() line id rest t
    while read -r line; do
      id=${line%% *}; rest=" $line "
      for t in "${tag_arr[@]}"; do
        if [[ $rest == *" $t "* ]]; then
          matched+=("$id")
          break
        fi
      done
    done < <(_build_tag_map)

    # De-duplicate while preserving original encounter order.
    local out=()
    declare -A _seen_ids=()
    for id in "${matched[@]}"; do
      if [[ -z ${_seen_ids[$id]} ]]; then
        out+=("$id")
        _seen_ids[$id]=1
      fi
    done
    echo "${out[*]}"
  }

  # ------------------------------------------------------------------------
  # ------------------------------------------------------------------------
  # Token parsing + expansion logic (shared by ONLY / EXCLUDE)
  # ------------------------------------------------------------------------
  _expand_mixed_spec() {
    # $1: raw spec string
    local raw=$1
    [[ -n $raw ]] || return 0
    local normalized
    # Replace delimiters with spaces
    normalized=$(echo "$raw" | tr ',;|' '   ')
    # shellcheck disable=SC2206
    local tokens=( $normalized )
    local numbers=() tag_tokens=() t start end n
    for t in "${tokens[@]}"; do
      if [[ $t =~ ^[0-9]+$ ]]; then
        numbers+=("$t")
        continue
      fi
      if [[ $t =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start=${BASH_REMATCH[1]} end=${BASH_REMATCH[2]}
        if (( start <= end )); then
          for (( n=start; n<=end; n++ )); do numbers+=("$n"); done
        else
          # If reversed range, swap (user convenience)
          for (( n=end; n<=start; n++ )); do numbers+=("$n"); done
        fi
        continue
      fi
        # Tag token (case-insensitive user input) -> store lowercase
      tag_tokens+=("${t,,}")
    done

    local resolved_ids=""
    if [[ ${#tag_tokens[@]} -gt 0 ]]; then
      resolved_ids=$(_resolve_ids_for_tags "${tag_tokens[@]}")
    fi

    # Merge numeric IDs (in user order & range expansion order) + tag IDs (discovery order)
    local final=()
    declare -A _seen_final=()
    for n in "${numbers[@]}"; do
      if [[ -z ${_seen_final[$n]} ]]; then final+=("$n"); _seen_final[$n]=1; fi
    done
    if [[ -n $resolved_ids ]]; then
      # shellcheck disable=SC2206
      local tag_ids=( $resolved_ids ) id
      for id in "${tag_ids[@]}"; do
        if [[ -z ${_seen_final[$id]} ]]; then final+=("$id"); _seen_final[$id]=1; fi
      done
    fi

    echo "${final[*]}"
  }

  # Return targets eligible for the current check/update scope. Tests and
  # callers with a computed scope may provide this list explicitly; normal
  # Proxmox runs derive it from the current cluster resource inventory.
  _filter_eligible_ids() {
    if [[ ${UU_FILTER_ELIGIBLE_IDS+x} ]]; then
      printf '%s\n' "${UU_FILTER_ELIGIBLE_IDS:-}"
      return 0
    fi
    command -v pvesh >/dev/null 2>&1 || return 1
    local resources
    resources=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null) || return 1
    python3 -c '
import json
import sys

_, with_lxc, with_vm, running_ct, stopped_ct, running_vm, stopped_vm, paused_vm = sys.argv[1:]
try:
    resources = json.load(sys.stdin)
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)

def enabled(value):
    return value.lower() == "true"

eligible = []
for resource in resources if isinstance(resources, list) else []:
    kind = resource.get("type")
    vmid = str(resource.get("vmid", ""))
    if kind not in {"lxc", "qemu"} or not vmid or resource.get("template"):
        continue
    state = str(resource.get("status", "")).lower()
    if kind == "lxc":
        if not enabled(with_lxc):
            continue
        if state == "running" and not enabled(running_ct):
            continue
        if state == "stopped" and not enabled(stopped_ct):
            continue
    else:
        if not enabled(with_vm):
            continue
        if state == "running" and not enabled(running_vm):
            continue
        if state == "stopped" and not enabled(stopped_vm):
            continue
        if state == "paused" and not enabled(paused_vm):
            continue
    eligible.append(vmid)
print(" ".join(eligible))
    ' "${UU_FILTER_SCOPE:-}" "${WITH_LXC:-}" "${WITH_VM:-}" \
      "${RUNNING:-${RUNNING_CONTAINER:-}}" "${STOPPED:-${STOPPED_CONTAINER:-}}" \
      "${RUNNING_VM:-}" "${STOPPED_VM:-}" "${PAUSED_VM:-}" <<< "$resources"
  }

  # EXCLUDE processing applies independently after any positive selection.
  EXCLUDE_TAG () {
    if [[ -n $_EXCLUDE_VALUE ]]; then
      local _expanded_exclude
      _expanded_exclude=$(_expand_mixed_spec "$_EXCLUDE_VALUE")
      printf -v "$_exclude_var_name" '%s' "$_expanded_exclude"
      if [[ -n $_expanded_exclude ]]; then
        _record_tag_log "ℹ ${OR:-} Exclusion (EXCLUDE='${_EXCLUDE_VALUE}') -> Target IDs: $_expanded_exclude${CL:-}\n"
      else
        _record_tag_log "ℹ ${BL:-} Exclusion (EXCLUDE='${_EXCLUDE_VALUE}') matched no eligible targets${CL:-}\n"
        return 0
      fi
    fi
  }

  # ONLY is a configured tag name, not an unconditional filter switch. It is
  # active only if at least one currently eligible target matches it.
  if [[ -n $_ONLY_VALUE ]]; then
    local _expanded_only
    _expanded_only=$(_expand_mixed_spec "$_ONLY_VALUE")
    local _eligible_only
    if _eligible_only=$(_filter_eligible_ids 2>/dev/null); then
      local _matched_only=() _candidate
      for _candidate in $_expanded_only; do
        if guest_id_matches "$_eligible_only" "$_candidate"; then
          _matched_only+=("$_candidate")
        fi
      done
      _expanded_only="${_matched_only[*]}"
    fi
    printf -v "$_only_var_name" '%s' "$_expanded_only"
    if [[ -n $_expanded_only ]]; then
      _record_tag_log "ℹ ${OR:-} Selection (ONLY='${_ONLY_VALUE}') -> Target IDs: $_expanded_only${CL:-}\n"
    else
      _record_tag_log "ℹ ${OR:-} Selection (ONLY='${_ONLY_VALUE}') matched no eligible targets; using all eligible targets${CL:-}\n"
    fi
  fi
  EXCLUDE_TAG
}
