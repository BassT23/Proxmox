#!/bin/bash

# Merge a distribution config into an existing user config without executing
# either file. Existing assignments always win; only missing assignments from
# the distribution file are appended.

CONFIG_MERGE_LOCK_SUFFIX=".lock"

CONFIG_MERGE_ASSIGNMENT_KEYS () {
  awk '
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
      line = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*=.*$/, "", line)
      if (!seen[line]++) print line
    }
  ' "$1"
}

CONFIG_MERGE_VALIDATE () {
  awk '
    BEGIN {
      sq = sprintf("%c", 39)
      double_value = "^\\\"([^\\\"\\\\]|\\\\.)*\\\"[[:space:]]*(#.*)?$"
      single_value = "^" sq "([^" sq "\\\\]|\\\\.)*" sq "[[:space:]]*(#.*)?$"
      bare_value = "^[^[:space:]#\\\"" sq "]+[[:space:]]*(#.*)?$"
    }
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
      line = substr($0, RSTART)
      sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*/, "", line)
      if (line !~ double_value && line !~ single_value && line !~ bare_value) {
        print "invalid assignment: " $0 > "/dev/stderr"
        invalid = 1
      }
    }
    END { exit invalid }
  ' "$1"
}

CONFIG_MERGE_DUPLICATES () {
  awk '
    match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
      line = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*/, "", line)
      sub(/[[:space:]]*=.*$/, "", line)
      if (++seen[line] > 1) duplicate = 1
    }
    END { exit duplicate }
  ' "$1"
}

CONFIG_MERGE_DEFAULT_BLOCK () {
  awk -v key="$1" '
    {
      if ($0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        for (i = 1; i <= comments; i++) print comment[i]
        print
        exit
      }
      if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) {
        comment[++comments] = $0
      } else {
        delete comment
        comments = 0
      }
    }
  ' "$2"
}

CONFIG_MERGE_SET_BRANCH () {
  local file="$1" branch="$2" temp

  [[ -n "$branch" ]] || return 0
  temp=$(mktemp "${file}.branch.XXXXXX") || return 1
  awk -v branch="$branch" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*USED_BRANCH[[:space:]]*=/ {
      print "USED_BRANCH=\"" branch "\"    # could be \"master/develop\""
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) print "\nUSED_BRANCH=\"" branch "\"    # could be \"master/develop\""
    }
  ' "$file" > "$temp" || { rm -f "$temp"; return 1; }
  mv -f "$temp" "$file"
}

MERGE_UPDATE_CONFIG () {
  local user_config="$1" default_config="$2" requested_branch="${3:-}"
  local lock_file temp backup key user_keys mode
  local lock_fd

  [[ -f "$default_config" ]] || {
    echo "Config merge source is missing: $default_config" >&2
    return 1
  }

  if [[ -e "$user_config" && ! -f "$user_config" ]]; then
    echo "Config merge target is not a regular file: $user_config" >&2
    return 1
  fi

  mkdir -p "$(dirname "$user_config")" || return 1
  lock_file="${user_config}${CONFIG_MERGE_LOCK_SUFFIX}"
  exec {lock_fd}>"$lock_file" || return 1
  if command -v flock >/dev/null 2>&1; then
    flock -x "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  fi

  if [[ -f "$user_config" ]]; then
    CONFIG_MERGE_VALIDATE "$user_config" || {
      echo "Existing update.conf contains an invalid assignment; leaving it unchanged." >&2
      exec {lock_fd}>&-
      return 1
    }
    CONFIG_MERGE_DUPLICATES "$user_config" || {
      echo "Existing update.conf contains duplicate assignments; leaving it unchanged." >&2
      exec {lock_fd}>&-
      return 1
    }
    cp -p "$user_config" "$user_config.merge-source" || {
      exec {lock_fd}>&-
      return 1
    }
  else
    : > "$user_config.merge-source" || { exec {lock_fd}>&-; return 1; }
  fi

  user_keys=$(mktemp) || { rm -f "$user_config.merge-source"; exec {lock_fd}>&-; return 1; }
  if [[ -f "$user_config" ]]; then
    CONFIG_MERGE_ASSIGNMENT_KEYS "$user_config" > "$user_keys" || {
      rm -f "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
  fi

  if [[ -f "$user_config" ]]; then
    mode=$(stat -c '%a' "$user_config" 2>/dev/null || printf '640')
    temp=$(mktemp "${user_config}.tmp.XXXXXX") || {
      rm -f "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
    cp "$user_config" "$temp" || {
      rm -f "$temp" "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
  else
    mode=640
    temp=$(mktemp "${user_config}.tmp.XXXXXX") || {
      rm -f "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
  fi

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! grep -Fqx "$key" "$user_keys"; then
      if [[ ! -s "$temp" ]] || [[ "$(tail -c 1 "$temp" 2>/dev/null)" != $'\n' ]]; then
        printf '\n' >> "$temp"
      fi
      CONFIG_MERGE_DEFAULT_BLOCK "$key" "$default_config" >> "$temp" || {
        rm -f "$temp" "$user_keys" "$user_config.merge-source"
        exec {lock_fd}>&-
        return 1
      }
      printf '\n' >> "$temp"
    fi
  done < <(CONFIG_MERGE_ASSIGNMENT_KEYS "$default_config")

  if [[ -n "$requested_branch" ]]; then
    if ! grep -Fqx 'USED_BRANCH' "$user_keys" ||
       ! awk -v branch="$requested_branch" '
         /^[[:space:]]*USED_BRANCH[[:space:]]*=/ {
           line = $0
           sub(/^[^=]*=[[:space:]]*/, "", line)
           if (line ~ "^\\\"" branch "\\\"") found = 1
         }
         END { exit !found }
       ' "$user_config" 2>/dev/null; then
      CONFIG_MERGE_SET_BRANCH "$temp" "$requested_branch" || {
        rm -f "$temp" "$user_keys" "$user_config.merge-source"
        exec {lock_fd}>&-
        return 1
      }
    fi
  fi

  CONFIG_MERGE_VALIDATE "$temp" || {
    echo "Merged update.conf failed validation; leaving existing config unchanged." >&2
    rm -f "$temp" "$user_keys" "$user_config.merge-source"
    exec {lock_fd}>&-
    return 1
  }
  CONFIG_MERGE_DUPLICATES "$temp" || {
    echo "Merged update.conf contains duplicate assignments; leaving existing config unchanged." >&2
    rm -f "$temp" "$user_keys" "$user_config.merge-source"
    exec {lock_fd}>&-
    return 1
  }

  if [[ ! -f "$user_config" ]] || ! cmp -s "$temp" "$user_config"; then
    if [[ -f "$user_config" ]]; then
      backup="${user_config}.bak.$(date +%Y%m%d-%H%M%S)"
      cp -p "$user_config" "$backup" || {
        rm -f "$temp" "$user_keys" "$user_config.merge-source"
        exec {lock_fd}>&-
        return 1
      }
    fi
    chmod "$mode" "$temp" || {
      rm -f "$temp" "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
    mv -f "$temp" "$user_config" || {
      rm -f "$temp" "$user_keys" "$user_config.merge-source"
      exec {lock_fd}>&-
      return 1
    }
  else
    rm -f "$temp"
  fi

  rm -f "$user_keys" "$user_config.merge-source"
  exec {lock_fd}>&-
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'Usage: %s USER_CONFIG DEFAULT_CONFIG [BRANCH]\n' "$0" >&2
    exit 2
  fi
  MERGE_UPDATE_CONFIG "$@"
fi
