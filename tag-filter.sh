#!/bin/bash
# Proxmox VM/CT Tag & ID Expansion Helper
#
# apply_only_exclude_tags ONLY_VAR_NAME EXCLUDE_VAR_NAME
# Expands ONLY (or if empty, EXCLUDE) into a space-separated list of numeric VMIDs.
# Supports:
#   - Plain VMIDs: 101 202
#   - Delimiters: commas / semicolons / pipes / spaces intermixed (e.g. 101,202;203|204)
#   - Ranges: 120-125 (inclusive)
#   - Mixed IDs + ranges + tags: 110 testing 111 200-202
#   - Uppercase user tag input (config tags assumed already lowercase)
#     Tag tokens are any token not matching ^[0-9]+$ or ^[0-9]+-[0-9]+$.
#   - OR matching across tag tokens.
#
# Behavior summary:
#   1. Tokenize ONLY if set; else tokenized EXCLUDE.
#   2. For each token:
#        number        -> add as VMID
#        range a-b     -> expand (a..b)
#        tag           -> collect tag for later resolution
#   3. Resolve tags to IDs (any tag match) and append, de-duplicating while
#      preserving first-seen order (input order then discovery order for tags).
#   4. Assign final space-separated list back to ONLY / EXCLUDE variable.
#   5. If ONLY provided, EXCLUDE is ignored (legacy behavior).
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
    local out=() seen=""
    for id in "${matched[@]}"; do
      if [[ ! $seen =~ (\s|^)$id(\s|$) ]]; then
        out+=("$id")
        seen+=" $id"
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
    local final=() seen=""
    for n in "${numbers[@]}"; do
      if [[ ! $seen =~ (\s|^)$n(\s|$) ]]; then final+=("$n"); seen+=" $n"; fi
    done
    if [[ -n $resolved_ids ]]; then
      # shellcheck disable=SC2206
      local tag_ids=( $resolved_ids ) id
      for id in "${tag_ids[@]}"; do
        if [[ ! $seen =~ (\s|^)$id(\s|$) ]]; then final+=("$id"); seen+=" $id"; fi
      done
    fi

    echo "${final[*]}"
  }

  # ONLY processing (takes precedence). Always parse mixed spec.
  if [[ -n $_ONLY_VALUE ]]; then
    local _expanded_only
    _expanded_only=$(_expand_mixed_spec "$_ONLY_VALUE")
    printf -v "$_only_var_name" '%s' "$_expanded_only"
    if [[ -n $_expanded_only ]]; then
      echo -e "${BL:-}[Info]${OR:-} Selection (ONLY='${_ONLY_VALUE}') -> IDs: $_expanded_only${CL:-}\n" 2>/dev/null || true
    else
      echo -e "${BL:-}[Info]${OR:-} Selection (ONLY='${_ONLY_VALUE}') matched no IDs${CL:-}\n" 2>/dev/null || true
    fi
    return 0
  fi

  # EXCLUDE processing (only when ONLY was empty)
  if [[ -n $_EXCLUDE_VALUE ]]; then
    local _expanded_exclude
    _expanded_exclude=$(_expand_mixed_spec "$_EXCLUDE_VALUE")
    printf -v "$_exclude_var_name" '%s' "$_expanded_exclude"
    if [[ -n $_expanded_exclude ]]; then
      echo -e "${BL:-}[Info]${OR:-} Exclusion (EXCLUDE='${_EXCLUDE_VALUE}') -> IDs: $_expanded_exclude${CL:-}\n" 2>/dev/null || true
    else
      echo -e "${BL:-}[Info]${OR:-} Exclusion (EXCLUDE='${_EXCLUDE_VALUE}') matched no IDs${CL:-}\n" 2>/dev/null || true
    fi
  fi
}
