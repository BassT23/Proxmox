#!/bin/bash

##################
# Welcome-Screen #
##################

# shellcheck disable=SC2034

VERSION="3.0"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
CHECK_OUTPUT=0
if [[ -f "$LOCAL_FILES/check-output" ]]; then
  CHECK_OUTPUT=$(stat -c%s "$LOCAL_FILES/check-output")
fi

# Colors
BL="\e[36m"
OR="\e[1;33m"
GN="\e[1;92m"
CL="\e[0m"

# shellcheck disable=SC1091
. "$LOCAL_FILES/tag-filter.sh"

# Version Check. This path intentionally uses only the local cache so SSH/MOTD
# login never waits for GitHub or another external service.
VERSION_CHECK () {
  local local_version candidate remote_version
  local -a candidates

  local_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh")
  echo -e "${BL}  Repo: ${OR}https://github.com/BassT23/Proxmox${CL}"
  echo -e "  Branch: ${OR}${BRANCH}${CL}"
  echo
  if ! READ_VERSION_CACHE; then
    echo -e "${OR}  Version cache unavailable; showing local version only.${CL}"
    echo -e "              Version: $local_version"
    echo
    return 0
  fi
  if [[ "$CACHE_FRESH" != true ]]; then
    echo -e "${OR}  Cached version information is stale.${CL}"
  fi

  case "$BRANCH" in
    master) candidates=(master) ;;
    beta) candidates=(master beta) ;;
    develop) candidates=(master beta develop) ;;
    *)
      echo -e "${OR}  Unknown branch '$BRANCH'; showing local version only.${CL}"
      echo -e "              Version: $local_version"
      echo
      return 0
      ;;
  esac

  VERSION_NOT_SHOW=false
  for candidate in "${candidates[@]}"; do
    case "$candidate" in
      master) remote_version=$CACHE_MASTER_VERSION ;;
      beta) remote_version=$CACHE_BETA_VERSION ;;
      develop) remote_version=$CACHE_DEVELOP_VERSION ;;
    esac
    if version_is_less "$local_version" "$remote_version"; then
      echo -e "${OR}       *** A newer version is available ***${CL}\n\
        Installed: $local_version / $candidate: $remote_version\n\
        ${OR}You can update with <update -up>${CL}"
      echo
      VERSION_NOT_SHOW=true
      break
    fi
  done
  if [[ "$VERSION_NOT_SHOW" != true ]]; then
    echo -e "${GN}       The Ultimate Updater is UpToDate${CL}"
    echo -e "              Version: $local_version"
    echo
  fi
}

READ_WRITE_CONFIG () {
  WITH_HOST=$(awk -F'"' '/^CHECK_WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^CHECK_WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^CHECK_WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING=$(awk -F'"' '/^CHECK_RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED=$(awk -F'"' '/^CHECK_STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE_UPDATE_CHECK=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY_UPDATE_CHECK=/ {print $2}' "$CONFIG_FILE")
  if [[ -f "$LOCAL_FILES/tag-filter.sh" ]]; then
    # shellcheck disable=SC1091
    . "$LOCAL_FILES/tag-filter.sh"
    if declare -f apply_only_exclude_tags >/dev/null 2>&1; then
      apply_only_exclude_tags ONLY EXCLUDED
    fi
  fi
  if [[ $ONLY != "" ]]; then
    echo -e "${OR}Only is set. Not all machines are checked.${CL}\n"
  elif [[ $ONLY == "" && $EXCLUDED != "" ]]; then
    echo -e "${OR}Exclude is set. Not all machines are checked.${CL}\n"
  elif [[ $WITH_HOST != true || $WITH_LXC != true || $WITH_VM != true || $RUNNING != true || $STOPPED != true ]]; then
    echo -e "${OR}The variable is set in config file. Some machines will not be checked!${CL}\n"
  fi
}

TIME_CALCULTION () {
  MOD=$(date -r "$LOCAL_FILES/check-output" +%s)
  NOW=$(date +%s)
  DAYS=$(( (NOW - MOD) / 86400 ))
  HOURS=$(( (NOW - MOD) / 3600 ))
  MINUTES=$(( (NOW - MOD) / 60 ))
}

COMPACT_WELCOME_OUTPUT () {
  awk '
    /^Normal updates: / {
      normal = $0
      sub(/^Normal updates: /, "", normal)
      next
    }
    /^Security updates: / {
      if (normal != "") {
        security = $0
        sub(/^Security updates: /, "", security)
        printf "S: %s / N: %s\n", security, normal
        normal = ""
        next
      }
    }
    {
      if (normal != "") {
        print "Normal updates: " normal
        normal = ""
      }
      print
    }
    END {
      if (normal != "") print "Normal updates: " normal
    }
  ' "$1"
}

# Welcome. Disk discovery is deliberately disabled: screenfetch/neofetch
# otherwise call df across every mounted filesystem, and a dead NFS/CIFS
# server can leave that syscall in uninterruptible kernel sleep. A login/MOTD
# path must not probe remote storage or rely on a network reachability guess.
if [[ -f /usr/bin/screenfetch ]]; then
  echo && timeout 10 screenfetch -d '-disk' -o 'shell_type="bash"' && echo
elif [[ -f /usr/bin/neofetch ]]; then
  echo
  timeout 10 neofetch --disable disk
else
  echo
fi
VERSION_CHECK
READ_WRITE_CONFIG
if [[ -f "$LOCAL_FILES/check-output" ]]; then
  TIME_CALCULTION
  if [[ $DAYS -gt 0 ]]; then
    echo -e "     Last Update Check: $DAYS day(s) ago\n"
  elif [[ $HOURS -gt 0 ]]; then
    echo -e "     Last Update Check: $HOURS hour(s) ago\n"
  else
    echo -e "     Last Update Check: $MINUTES minute(s) ago\n"
  fi
  if [[ $CHECK_OUTPUT -gt 0 ]]; then
    echo -e "${OR}Available Updates:${CL}"
    echo -e "S = Security / N = Normal"
    echo
    COMPACT_WELCOME_OUTPUT "$LOCAL_FILES/check-output"
  fi
  echo
fi

exit 0
