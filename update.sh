#!/bin/bash

##########
# Update #
##########

VERSION="5.1"

# A protection failure must make the overall update job fail, even when the
# configured continue-on-error mode allows other guests to be processed.
SAFETY_FAILURE=false
# Continue-on-error keeps processing later targets, but real target failures
# must still produce a non-zero final update result.
UPDATE_FAILURE=false

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="$LOCAL_FILES/update.conf"
USER_SCRIPTS="/etc/ultimate-updater/scripts.d"
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
fi
CLUSTER_TARGET_FILE="${CLUSTER_TARGET_FILE:-$LOCAL_FILES/cluster-target.sh}"
if [[ -f "$CLUSTER_TARGET_FILE" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$CLUSTER_TARGET_FILE"
fi
WINDOWS_UPDATE_FILE="${WINDOWS_UPDATE_FILE:-$LOCAL_FILES/windows-update.sh}"
if [[ -f "$WINDOWS_UPDATE_FILE" ]]; then
  # shellcheck disable=SC1090
  . "$WINDOWS_UPDATE_FILE"
fi
if [[ -f "$LOCAL_FILES/status-model.sh" ]]; then
  # shellcheck disable=SC1090,SC1091
  . "$LOCAL_FILES/status-model.sh"
fi
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "$CONFIG_FILE")
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"
if [[ "$BRANCH" == beta ]]; then
  echo -e "${OR:-}The beta branch is no longer active; using develop instead.${CL:-}"
  BRANCH=develop
  SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"
fi
DPKG_OPTIONS=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DPKG_OPTIONS_STRING="${DPKG_OPTIONS[*]}"

# Tag filter
# shellcheck disable=SC1091
. "$LOCAL_FILES/tag-filter.sh"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"



# Header
HEADER_INFO () {
  clear
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
    if [[ "$HEADLESS" == true ]]; then
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

# Check internet status
CHECK_INTERNET () {
  if ! "$CHECK_URL_EXE" -q -c1 "$CHECK_URL" &>/dev/null; then
    echo -e "\n${OR:-} ❌ Internet check fail - Can't update without internet${CL:-}\n"
    exit 2
  fi
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
            if [[ "$CLUSTER_TARGET_LOCAL" == false ]]; then
              local remote_command
              printf -v remote_command 'exec %q start %q %q' \
                "/etc/ultimate-updater/job-runner.sh" "/etc/ultimate-updater/update.sh" "$ARGUMENT"
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
        if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Exit, if error come up, is disabled${CL:-}\n"; fi
        echo -e "ℹ ${OR:-} Update only LXC/VM $ARGUMENT - work only on main host!${CL:-}\n"
        CONTAINER_UPDATE_START
        VM_UPDATE_START
        ;;
      -h|--help) USAGE; exit 0 ;;
      -v|--version) VERSION_CHECK; exit 0 ;;
      -s|--silent) HEADLESS=true ;;
      -c) RICM=true ;;
      -w) WELCOME_SCREEN=true ;;
      host)
        COMMAND=true
        TAG_LOG=true
        if [[ "$RICM" != true ]]; then
          MODE="  Host  "
          HEADER_INFO
          if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Exit, if error come up, is disabled${CL:-}\n"; fi
        fi
        echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
        if [[ "$WITH_HOST" == true ]]; then
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
      master|develop)
        if [[ "$2" != -up ]]; then
          echo -e "\n${OR:-}  Wrong usage! Use branch update like this:${CL:-}"
          echo -e "  update $ARGUMENT -up\n"
          exit 2
        fi
        BRANCH=$ARGUMENT
        BRANCH_SET=true
        ;;
      -up)
        COMMAND=true
        if [[ "$BRANCH_SET" != true ]]; then
          BRANCH=master
        fi
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
        $LOCAL_FILES/check-updates.sh
        exit 2
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
  if [[ "$HEADLESS" != true ]]; then
    echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
    echo -e "[OPTIONS] Manages the Ultimate Updater:"
    echo -e "======================================"
    echo -e "  master               Use master branch"
    echo -e "  develop              Use develop branch\n"
    echo -e "{COMMAND}:"
    echo -e "========="
    echo -e "  -s --silent          Silent / Headless Mode"
    echo -e "  -h --help            Show help menu"
    echo -e "  -v --version         Show The Ultimate Updater version"
    echo -e "  -dist-upgrade        Run distribution upgrade (Debian 12 -> 13)"
    echo -e "  -check               Run check-updates.sh"
    echo -e "  -up                  Update The Ultimate Updater"
    echo -e "  status               Show Status (Version Infos)"
    echo -e "  uninstall            Uninstall The Ultimate Updater\n"
    echo -e "  host                 Host-Mode"
    echo -e "  cluster              Cluster-Mode\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

# Version Check / Update Message in Header
RUN_BRANCH_UPDATE () {
  local target_branch=$1 installer

  if ! installer=$(curl -fsSL --connect-timeout 3 --max-time 10 \
    "https://raw.githubusercontent.com/BassT23/Proxmox/$target_branch/install.sh"); then
    echo -e "${RD:-}Unable to download the $target_branch installer.${CL:-}"
    return 1
  fi
  printf '%s\n' "$installer" | bash -s update
}

SHOW_UPDATE_NOTICE () {
  local target_branch=$1 remote_version=$2

  echo -e "${OR:-}*** A newer version is available ***${CL:-}\n\
       Installed: $LOCAL_VERSION / $target_branch: $remote_version"
  if [[ "$HEADLESS" != true ]]; then
    echo -e "${OR:-}Want to update The Ultimate Updater first?${CL:-}"
    read -p "Type [Y/y] or Enter for yes - anything else will skip: " -r
    if [[ "$REPLY" =~ ^[Yy]$ || "$REPLY" = "" ]]; then
      RUN_BRANCH_UPDATE "$target_branch"
    fi
    echo
  fi
}

VERSION_CHECK () {
  local candidate remote_version remote_available=false
  local -a candidates

  LOCAL_VERSION=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh")
  case "$BRANCH" in
    master) candidates=(master) ;;
    develop) candidates=(master develop) ;;
    *)
      echo -e "${OR:-}The configured branch '$BRANCH' is not active; use master or develop.${CL:-}"
      echo -e "                 Version: $VERSION"
      return 0
      ;;
  esac

  if [[ "$BRANCH" == develop ]]; then
    echo -e "${OR:-}*** The Ultimate Updater is on develop branch ***${CL:-}"
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
    echo -e "${GN:-}       The Ultimate Updater is UpToDate${CL:-}"
    echo -e "                 Version: $VERSION"
  elif [[ "$VERSION_NOT_SHOW" != true ]]; then
    echo -e "${OR:-}       Unable to verify the remote version${CL:-}"
    echo -e "                 Version: $VERSION"
  fi
}

# Update The Ultimate Updater
UPDATE () {
  SELF_UPDATE_RUN=true
  echo -e "Update to $BRANCH branch?"
  if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
    UU_NONINTERACTIVE=true bash <(curl -s "https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"/install.sh) update
    return $?
  fi
  read -p "Type [Y/y] or [Enter] for yes - anything else will exit: " -r
  if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
    UU_NONINTERACTIVE=true bash <(curl -s "https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"/install.sh) update
    return $?
  else
    return 2
  fi
}

# Uninstall
UNINSTALL () {
  echo -e "\n⚠ ${OR:-} Uninstall The Ultimate Updater${CL:-}\n"
  echo -e "${RD:-}Really want to remove The Ultimate Updater?${CL:-}"
  read -p "Type [Y/y] for yes - anything else will exit: " -r
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    bash <(curl -s "$SERVER_URL"/install.sh) uninstall
    exit 2
  else
    exit 2
  fi
}

# Get Server Versions
STATUS () {
  local branch_for_status=$BRANCH component label local_file local_version remote_version
  local -a components=(
    "Updater|update.sh|$LOCAL_FILES/update.sh"
    "Extras|update-extras.sh|$LOCAL_FILES/update-extras.sh"
    "Config|update.conf|$LOCAL_FILES/update.conf"
  )

  if [[ "$WELCOME_SCREEN" == true ]]; then
    components+=("Welcome|welcome-screen.sh|/etc/update-motd.d/01-welcome-screen")
    components+=("Check|check-updates.sh|$LOCAL_FILES/check-updates.sh")
  fi
  if [[ "$branch_for_status" == beta ]]; then
    branch_for_status=develop
    echo -e "${OR:-}The beta branch is no longer active; showing develop instead.${CL:-}"
  fi
  if [[ "$branch_for_status" != master && "$branch_for_status" != develop ]]; then
    echo -e "${RD:-}Unknown branch '$BRANCH'; status cannot be retrieved.${CL:-}"
    return 1
  fi

  echo -e "${OR:-}  Version overview ($branch_for_status)${CL:-}\n"
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
  WITH_HOST=$(awk -F'"' '/^WITH_HOST=/ {print $2}' "$CONFIG_FILE")
  WITH_LXC=$(awk -F'"' '/^WITH_LXC=/ {print $2}' "$CONFIG_FILE")
  WITH_VM=$(awk -F'"' '/^WITH_VM=/ {print $2}' "$CONFIG_FILE")
  RUNNING_CONTAINER=$(awk -F'"' '/^RUNNING_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  STOPPED_CONTAINER=$(awk -F'"' '/^STOPPED_CONTAINER=/ {print $2}' "$CONFIG_FILE")
  RUNNING_VM=$(awk -F'"' '/^RUNNING_VM=/ {print $2}' "$CONFIG_FILE")
  STOPPED_VM=$(awk -F'"' '/^STOPPED_VM=/ {print $2}' "$CONFIG_FILE")
  FREEBSD_UPDATES=$(awk -F'"' '/^FREEBSD_UPDATES=/ {print $2}' "$CONFIG_FILE")
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
  EXTRA_IN_HEADLESS=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' "$CONFIG_FILE")
  EXCLUDED=$(awk -F'"' '/^EXCLUDE=/ {print $2}' "$CONFIG_FILE")
  ONLY=$(awk -F'"' '/^ONLY=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_PHASED_UPDATES=$(awk -F'"' '/^INCLUDE_PHASED_UPDATES=/ {print $2}' "$CONFIG_FILE")
  INCLUDE_FSTRIM=$(awk -F'"' '/^INCLUDE_FSTRIM=/ {print $2}' "$CONFIG_FILE")
  FSTRIM_WITH_MOUNTPOINT=$(awk -F'"' '/^FSTRIM_WITH_MOUNTPOINT=/ {print $2}' "$CONFIG_FILE")
  PACMAN_ENVIRONMENT=$(awk -F'"' '/^PACMAN_ENVIRONMENT=/ {print $2}' "$CONFIG_FILE")
  declare -f apply_only_exclude_tags >/dev/null 2>&1 && apply_only_exclude_tags ONLY EXCLUDED
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
CONTAINER_BACKUP () {
  local snapshot_requested="$SNAPSHOT"
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if pct snapshot "$CONTAINER" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshots${CL:-}"
        LIST=$(pct listsnapshot "$CONTAINER" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          pct delsnapshot "$CONTAINER" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "✅${GN:-} Done${CL:-}"
      else
        echo -e "❌${RD:-} Snapshot creation failed for LXC $CONTAINER${CL:-}"
        if [[ "$backup_requested" == true ]]; then
          backup_requested=true
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        elif [[ "$BACKUP_LXC_MP" == true ]] && pct config "$CONTAINER" | grep -q '^mp'; then
          backup_requested=true
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Changed to backup, because of mount points${CL:-}"
        else
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
      if vzdump "$CONTAINER" --mode "$MODE" --notes-template "{{guestname}} - Ultimate-Updater" --storage "$STORAGE" --compress zstd; then
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
  local snapshot_requested="$SNAPSHOT"
  local backup_requested="$BACKUP"

  if [[ "$snapshot_requested" == true || "$backup_requested" == true ]]; then
    if [[ "$snapshot_requested" == true ]]; then
      if qm snapshot "$VM" "Update_$(date '+%Y%m%d_%H%M%S')" &>/dev/null; then
        echo -e "✅${GN:-} Snapshot created${CL:-}"
        echo -e "ℹ ${GN:-} Delete old snapshot(s)${CL:-}"
        LIST=$(qm listsnapshot "$VM" | sed -n "s/^.*Update\s*\(\S*\).*$/\1/p" | head -n -"$KEEP_SNAPSHOT")
        for SNAPSHOTS in $LIST; do
          qm delsnapshot "$VM" Update"$SNAPSHOTS" >/dev/null 2>&1
        done
      echo -e "✅${GN:-} Done${CL:-}"
      else
        echo -e "❌${RD:-} Snapshot creation failed for VM $VM${CL:-}"
        if [[ "$backup_requested" == true ]]; then
          snapshot_requested=false
          echo -e "ℹ ${OR:-} Attempting configured backup fallback${CL:-}"
        else
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
      if vzdump "$VM" --mode "$MODE" --storage "$STORAGE" --compress zstd; then
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
  if [[ "$EXTRA_GLOBAL" != true ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of the user settings ---${CL:-}\n"
  elif [[ "$HEADLESS" == true && "$EXTRA_IN_HEADLESS" == false ]]; then
    echo -e "\n${OR:-}--- Skip Extra Updates because of Headless Mode or user settings ---${CL:-}\n"
  else
    echo -e "\n${OR:-}--- Searching for extra updates ---${CL:-}"
    if [[ "$SSH_CONNECTION" != true ]]; then
      pct exec "$CONTAINER" -- bash -c "mkdir -p $LOCAL_FILES/"
      pct push "$CONTAINER" -- $LOCAL_FILES/update-extras.sh $LOCAL_FILES/update-extras.sh
      pct push "$CONTAINER" -- $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf
      pct exec "$CONTAINER" -- bash -c "chmod +x $LOCAL_FILES/update-extras.sh && \
                                        $LOCAL_FILES/update-extras.sh && \
                                        rm -rf $LOCAL_FILES || true"
      USER_SCRIPTS
    # Extras in VMS with SSH_CONNECTION
    elif [[ "$USER" != root ]]; then
      echo -e "${RD:-}--- You need root user for extra updates - maybe in later relaeses possible ---${CL:-}"
    else
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" mkdir -p $LOCAL_FILES/
      scp $LOCAL_FILES/update-extras.sh "$IP":$LOCAL_FILES/update-extras.sh
      scp $LOCAL_FILES/update.conf "$IP":$LOCAL_FILES/update.conf
      ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "chmod +x $LOCAL_FILES/update-extras.sh && \
                $LOCAL_FILES/update-extras.sh && \
                rm -rf $LOCAL_FILES || true"
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
  if [[ "$WELCOME_SCREEN" == true ]]; then
    local status_target=""
    echo -e "${OR:-}--- Check Status for Welcome-Screen ---${CL:-}"
    if [[ "$CHOST" == true ]]; then
#      ssh -q -p "$SSH_PORT" "$HOSTNAME" "\"$LOCAL_FILES/check-updates.sh\" -u chost" | tee -a "$LOCAL_FILES/check-output"
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u chost | tee -a "$LOCAL_FILES/check-output"
      status_target="host:$HOSTNAME"
    elif [[ "$CCONTAINER" == true ]]; then
#      ssh -q -p "$SSH_PORT" "$HOSTNAME" "\"$LOCAL_FILES/check-updates.sh\" -u ccontainer" | tee -a $LOCAL_FILES/check-output
      STATUS_MODEL_PARTIAL=true "$LOCAL_FILES/check-updates.sh" -u ccontainer | tee -a "$LOCAL_FILES/check-output"
      status_target="$CONTAINER"
    elif [[ "$CVM" == true ]]; then
      ssh -q -p "$SSH_PORT" "$HOSTNAME" "\"$LOCAL_FILES/check-updates.sh\" -u cvm" | tee -a $LOCAL_FILES/check-output
      status_target="$VM"
    fi
    if [[ -n "$status_target" ]] && declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$status_target" success 0 || true
    fi
    echo -e "${GN:-}---          Finished check         ---${CL:-}\n"
    [[ "$WILL_STOP" != true ]] && echo
  else
    echo
  fi
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

# Execute one QEMU Guest Agent command and decode the structured response.
# The qm CLI returns zero when the request succeeded, even if the command in
# the guest returned a non-zero exit code. Keep both statuses available to
# callers so transport and guest failures are not conflated.
QEMU_GUEST_EXEC () {
  QEMU_EXEC_STDOUT=""
  QEMU_EXEC_STDERR=""
  QEMU_EXEC_OUTPUT=""
  QEMU_EXEC_EXITCODE=""
  QEMU_EXEC_TRANSPORT_RC=0
  local QEMU_RAW QEMU_PARSED QEMU_STATUS

  QEMU_RAW=$(qm guest exec "$@" 2>&1)
  QEMU_STATUS=$?
  if [[ $QEMU_STATUS -ne 0 ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=$QEMU_STATUS
    return 0
  fi

  if ! QEMU_PARSED=$(printf '%s' "$QEMU_RAW" | python3 -c '
import base64
import json
import sys

try:
    response = json.load(sys.stdin)
except (TypeError, ValueError):
    sys.exit(1)

for key in ("out-data", "err-data"):
    value = response.get(key, "")
    if not isinstance(value, str):
        value = str(value)
    print(base64.b64encode(value.encode()).decode())

exitcode = response.get("exitcode", 0)
if not isinstance(exitcode, int) or exitcode < 0:
    sys.exit(1)
print(exitcode)
'); then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi

  local -a QEMU_FIELDS
  mapfile -t QEMU_FIELDS <<< "$QEMU_PARSED"
  if [[ ${#QEMU_FIELDS[@]} -ne 3 || ! ${QEMU_FIELDS[2]} =~ ^[0-9]+$ ]]; then
    QEMU_EXEC_STDERR="$QEMU_RAW"
    QEMU_EXEC_OUTPUT="$QEMU_RAW"
    QEMU_EXEC_TRANSPORT_RC=1
    return 0
  fi
  IFS= read -r -d '' QEMU_EXEC_STDOUT < <(printf '%s' "${QEMU_FIELDS[0]}" | base64 -d) || true
  IFS= read -r -d '' QEMU_EXEC_STDERR < <(printf '%s' "${QEMU_FIELDS[1]}" | base64 -d) || true
  QEMU_EXEC_EXITCODE=${QEMU_FIELDS[2]}
  if [[ -n "$QEMU_EXEC_STDOUT" && -n "$QEMU_EXEC_STDERR" ]]; then
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}
${QEMU_EXEC_STDERR}"
  else
    QEMU_EXEC_OUTPUT="${QEMU_EXEC_STDOUT}${QEMU_EXEC_STDERR}"
  fi
  return 0
}

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

CHECK_QGA_EXEC () {
  QEMU_GUEST_EXEC "$VM" -- true
  if [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 && "$QEMU_EXEC_EXITCODE" -eq 0 ]]; then
    return 0
  fi
  if grep -Eqi 'not allowed|disabled|not permitted|permission denied' <<< "$QEMU_EXEC_OUTPUT"; then
    QGA_ERROR="QEMU Guest Agent is reachable on VM $VM, but guest-exec is disabled or not allowed: $QEMU_EXEC_OUTPUT"
  elif [[ $QEMU_EXEC_TRANSPORT_RC -eq 0 ]]; then
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
  if [[ "$RICM" != true ]]; then true > $LOCAL_FILES/check-output; fi
  for HOST in $HOSTS; do
    # Check if Host/Node is available
    if ssh -q -p "$SSH_PORT" "$HOST" test >/dev/null 2>&1; [ $? -eq 255 ]; then
      echo -e "⏩ ${OR:-}Skip Host${CL:-} : ${GN:-}$HOST${CL:-} ${OR:-}- can't connect${CL:-}\n"
      UPDATE_FAILURE=true
    else
      if ! UPDATE_HOST "$HOST"; then
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# Host Update
UPDATE_HOST () {
  HOST=$1
  START_HOST=$(hostname -i | cut -d ' ' -f1)
  if [[ "$HOST" != "$START_HOST" ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" mkdir -p $LOCAL_FILES/temp
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf ]]; then cp -p $LOCAL_FILES/update.conf $LOCAL_FILES/update.conf.uu-backup; else rm -f $LOCAL_FILES/update.conf.uu-backup; fi"
    scp "$0" "$HOST":$LOCAL_FILES/update
    scp $LOCAL_FILES/update-extras.sh "$HOST":$LOCAL_FILES/update-extras.sh
    scp $LOCAL_FILES/update.conf "$HOST":$LOCAL_FILES/update.conf
    if [[ -f $LOCAL_FILES/update.conf.dist ]]; then
      scp $LOCAL_FILES/update.conf.dist "$HOST":$LOCAL_FILES/update.conf.dist
    fi
    if [[ "$WELCOME_SCREEN" == true ]]; then
      scp $LOCAL_FILES/check-updates.sh "$HOST":$LOCAL_FILES/check-updates.sh
      scp $LOCAL_FILES/check-output "$HOST":$LOCAL_FILES/check-output
    fi
    scp /etc/ultimate-updater/temp/exec_host "$HOST":/etc/ultimate-updater/temp
    scp -r $LOCAL_FILES/VMs/ "$HOST":$LOCAL_FILES/
    if [[ -f $LOCAL_FILES/tag-filter.sh ]]; then
      scp $LOCAL_FILES/tag-filter.sh "$HOST":$LOCAL_FILES/tag-filter.sh
    fi
    if [[ -f "$LOCAL_FILES/target-runtime.sh" ]]; then
      scp "$LOCAL_FILES/target-runtime.sh" "$HOST":$LOCAL_FILES/target-runtime.sh
    fi
    if [[ -f "$LOCAL_FILES/cluster-target.sh" ]]; then
      scp "$LOCAL_FILES/cluster-target.sh" "$HOST":$LOCAL_FILES/cluster-target.sh
    fi
  fi
  if [[ "$HEADLESS" == true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-s -c host"
    REMOTE_UPDATE_STATUS=$?
  elif [[ "$WELCOME_SCREEN" == true ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-c -w host"
    REMOTE_UPDATE_STATUS=$?
  else
    ssh -q -p "$SSH_PORT" "$HOST" 'bash -s' < "$0" -- "-c host"
    REMOTE_UPDATE_STATUS=$?
  fi
  if [[ "$HOST" != "$START_HOST" ]]; then
    ssh -q -p "$SSH_PORT" "$HOST" "if [[ -f $LOCAL_FILES/update.conf.uu-backup ]]; then mv -f $LOCAL_FILES/update.conf.uu-backup $LOCAL_FILES/update.conf; else rm -f $LOCAL_FILES/update.conf; fi"
  fi
  return "${REMOTE_UPDATE_STATUS:-0}"
}

# shellcheck disable=SC2015
UPDATE_HOST_ITSELF () {
  echo -e "${OR:-}--- PVE UPDATE ---${CL:-}" && pveupdate || true
  if [[ "$HEADLESS" == true ]]; then
    echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}" && \
    DEBIAN_FRONTEND=noninteractive apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG=$(DEBIAN_FRONTEND=noninteractive apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
  else
    if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG=$(apt-get "${DPKG_OPTIONS[@]}" dist-upgrade -y 2>&1); ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}" && \
      apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG=$(apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y 2>&1); ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
    fi
  fi
  echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}" && \
  apt-get --purge autoremove -y || { ERROR_CODE=$?; ID=$HOSTNAME; NAME=$HOSTNAME; ERROR_MSG=$(apt-get --purge autoremove -y 2>&1); ERROR; }
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
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    ERROR_CODE=""
    if [[ "$ONLY" == "" ]] && guest_id_matches "$EXCLUDED" "$CONTAINER"; then
      echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$CONTAINER"; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"; else continue; fi
    elif (pct config "$CONTAINER" | grep template >/dev/null 2>&1); then
      echo -e "⏩ ${OR:-}LXC $CONTAINER is a template - skip update${CL:-}\n\n"
      continue
    else
      STATUS=$(pct status "$CONTAINER")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" == true ]]; then
        # Start the container
        WILL_STOP="true"
        echo -e " ▶${GN:-} Starting LXC ${BL:-}$CONTAINER ${CL:-}"
        pct start "$CONTAINER"
        echo -e "⏳${GN:-} Waiting for LXC ${BL:-}$CONTAINER${CL:-}${GN:-} to start ${CL:-}"
#        sleep "$LXC_START_DELAY"
        if WAIT_FOR_BOOTUP_LXC; then
          UPDATE_CONTAINER "$CONTAINER"
        else
          ERROR_CODE=$?
          ID=$CONTAINER
          NAME="LXC $CONTAINER"
          ERROR_MSG="LXC $CONTAINER did not become reachable after the boot wait timeout"
          ERROR
        fi
        # Stop the container
        echo -e "⏹ ${GN:-} Shutting down LXC ${BL:-}$CONTAINER ${CL:-}\n\n"
        pct shutdown "$CONTAINER" &
        WILL_STOP="false"
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" == true ]]; then
        UPDATE_CONTAINER "$CONTAINER"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_CONTAINER" != true ]]; then
        echo -e "⏩${BL:-} Skipped LXC $CONTAINER by the user${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
  rm -rf /etc/ultimate-updater/temp/temp
}

# Container Update
UPDATE_CONTAINER () {
  CONTAINER=$1
  CCONTAINER="true"
  echo 'CONTAINER="'"$CONTAINER"'"' > /etc/ultimate-updater/temp/var
  OS=$(pct config "$CONTAINER" | awk '/^ostype/' - | cut -d' ' -f2)
  NAME=$(pct exec "$CONTAINER" hostname)
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
    SCRIPT_ONLY_RUN=true
    SCRIPT_ONLY_LXC || {
      ERROR_CODE=$?
      ID=$CONTAINER
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    if [[ -z "${ERROR_CODE:-}" ]] && declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
      STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
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
        STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
      else
        STATUS_MODEL_UPDATE_RESULT "$CONTAINER" failed "$dist_result" || true
      fi
    fi
    return "$dist_result"
  elif [[ "$CHECK_DIST" == true ]]; then
    echo -e "${OR:-} ❌ Distribution not supported\n${CL:-}"
    return 0
  fi
  # Run update
  # shellcheck disable=SC2015
  if [[ "${OS,,}" =~ ubuntu|debian|devuan ]]; then
    echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
    # Check APT in Container for Unifi before update
    if pct exec "$CONTAINER" -- bash -c "grep -rnw /etc/apt -e unifi >/dev/null 2>&1"; then
      UNIFI="true"
      # --allow-releaseinfo-change needed because Unifi regularly changes repository metadata between versions
      pct exec "$CONTAINER" -- bash -c "apt-get update --allow-releaseinfo-change" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get update --allow-releaseinfo-change" 2>&1); ERROR; }
    else
      pct exec "$CONTAINER" -- bash -c "apt-get update" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get update" 2>&1); ERROR; }
    fi
    if [[ $ERROR_CODE != "" ]]; then return; fi
    # Check END
    if [[ "$HEADLESS" == true ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" 2>&1); ERROR; }
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    elif [[ "$UNIFI" == true ]]; then
      echo -e "\n${OR:-}--- APT UPGRADE HEADLESS (Unifi) ---${CL:-}"
      # Use --force-confdef/--force-confold to suppress Unifi interactive prompts
      pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" 2>&1); ERROR; }
      UNIFI=""
      if [[ $ERROR_CODE != "" ]]; then return; fi
    else
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING dist-upgrade -y" 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y" 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
    fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get --purge autoremove -y" 2>&1); ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      pct exec "$CONTAINER" -- bash -c "apt-get autoclean -y" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "apt-get autoclean -y" 2>&1); ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      EXTRAS
      TRIM_FILESYSTEM
      UPDATE_CHECK
  elif [[ "$OS" =~ fedora ]]; then
    echo -e "\n${OR:-}--- DNF UPGRATE ---${CL:-}"
    pct exec "$CONTAINER" -- bash -c "dnf -y upgrade" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "dnf -y upgrade" 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
    pct exec "$CONTAINER" -- bash -c "dnf -y autoremove" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "dnf -y autoremove" 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ archlinux ]]; then
    echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
    pct exec "$CONTAINER" -- bash -c "$PACMAN_ENVIRONMENT pacman -Su --noconfirm" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "$PACMAN_ENVIRONMENT pacman -Su --noconfirm" 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  elif [[ "$OS" =~ alpine ]]; then
    echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
    pct exec "$CONTAINER" -- ash -c "apk -U upgrade" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- ash -c "apk -U upgrade" 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    if [[ "$WILL_STOP" != true ]]; then echo; fi
    echo
  elif [[ "$OS" =~ centos ]]; then
    echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
    pct exec "$CONTAINER" -- bash -c "yum -y update" || { ERROR_CODE=$?; ID=$CONTAINER; ERROR_MSG=$(pct exec "$CONTAINER" -- bash -c "yum -y update" 2>&1); ERROR; }
    if [[ $ERROR_CODE != "" ]]; then return; fi
    EXTRAS
    TRIM_FILESYSTEM
    UPDATE_CHECK
  else
    echo -e "${OR:-}The system could not be idetified.${CL:-}"
  fi
  if declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1; then
    STATUS_MODEL_UPDATE_RESULT "$CONTAINER" success 0 || true
  fi
  CCONTAINER=""
}

############################
########### VM #############
############################

# VM Update Start
VM_UPDATE_START () {
  # Get the list of VMs
  VMS=$(qm list | tail -n +2 | cut -c -10)
  # Loop through the VMs
  for VM in $VMS; do
    PRE_OS=$(qm config "$VM" | grep ostype || true)
    if [[ "$ONLY" == "" ]] && guest_id_matches "$EXCLUDED" "$VM"; then
      echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
    elif [[ "$ONLY" != "" ]] && ! guest_id_matches "$ONLY" "$VM"; then
      if [[ "$SINGLE_UPDATE" != true ]]; then echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"; else continue; fi
    elif (qm config "$VM" | grep template >/dev/null 2>&1); then
      echo -e "⏩${BL:-} ${OR:-}VM $VM is a template - skip update${CL:-}\n\n"
      continue
    elif [[ "$PRE_OS" =~ w ]]; then
      echo -e "⚠ ${BL:-} Skipped VM $VM${CL:-}\n"
      echo -e "${OR:-}  Windows is not supported for now.\n  I'm working on it ;)${CL:-}\n\n"
    else
      STATUS=$(qm status "$VM")
      if [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" == true ]]; then
        # Check if update is possible
        if [[ $(qm config "$VM" | grep 'agent:' | sed 's/agent:\s*//') == 1 || -f $LOCAL_FILES/VMs/$VM ]]; then
          # Start the VM
          WILL_STOP="true"
          echo -e " ▶${GN:-} Starting VM${BL:-} $VM ${CL:-}"
          qm start "$VM" >/dev/null 2>&1
          START_WAITING="true"
          UPDATE_VM "$VM"
          # Stop the VM
          echo -e "⏹ ${GN:-} Shutting down VM${BL:-} $VM ${CL:-}\n\n"
          qm shutdown "$VM" &
          WILL_STOP="false"
          START_WAITING="false"
        else
          echo -e "⏩${BL:-} Skipped VM $VM because, QEMU or SSH hasn't initialized${CL:-}\n\n"
        fi
      elif [[ "$STATUS" == "status: stopped" && "$STOPPED_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" == true ]]; then
        UPDATE_VM "$VM"
      elif [[ "$STATUS" == "status: running" && "$RUNNING_VM" != true ]]; then
        echo -e "⏩${BL:-} Skipped VM $VM by the user${CL:-}\n\n"
      else
        echo -e "⚠ Can't find status, please report this issue${CL:-}\n\n"
        UPDATE_FAILURE=true
      fi
    fi
  done
}

# VM Update
# shellcheck disable=SC2015
UPDATE_VM () {
  VM=$1
  NAME=$(qm config "$VM" | grep 'name:' | sed 's/name:\s*//')
  CVM="true"
  echo 'VM="'"$VM"'"' > /etc/ultimate-updater/temp/var
  echo -e "🔄${GN:-} Updating VM ${BL:-}$VM${CL:-} : ${GN:-}$NAME${CL:-}\n"
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
    SCRIPT_ONLY_RUN=true
    SCRIPT_ONLY_VM || {
      ERROR_CODE=$?
      ID=$VM
      ERROR_MSG="${SCRIPT_ONLY_ERROR:-Script-only user scripts failed or were not found}"
      ERROR
    }
    CVM=""
    return
  fi
  # Read SSH config file - check how update is possible
  if [[ -f $LOCAL_FILES/VMs/"$VM" ]]; then
    IP=$(awk -F'"' '/^IP=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    USER=$(awk -F'"' '/^USER=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    USER="${USER:-root}"
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' $LOCAL_FILES/VMs/"$VM")
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-45}"
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
  Infos can be found here:<https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>
  Try to use QEMU insead\n"
      START_WAITING=false
      UPDATE_VM_QEMU
    else
      # Run SSH Update
      SSH_CONNECTION="true"
      KERNEL=$(qm guest cmd "$VM" get-osinfo 2>/dev/null | grep kernel-version || true)
      OS=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" hostnamectl 2>/dev/null | grep System || true)
      # Free-BSD
      if [[ $KERNEL =~ FreeBSD && $FREEBSD_UPDATES == true ]]; then
        echo -e "${OR:-}--- PKG UPDATE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg update || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg update 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG UPGRADE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg upgrade -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg upgrade -y 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- PKG CLEANING ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg autoremove -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pkg autoremove -y 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo
        return
      elif [[ "$KERNEL" =~ FreeBSD ]]; then
        echo -e "${OR:-} Free BSD skipped by user${CL:-}\n"
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
        echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER"apt-get update -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER"apt-get update -y 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
        if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
          ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" upgrade -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" upgrade -y 2>&1); ERROR; }
          if [[ $ERROR_CODE != "" ]]; then return; fi
        else
          ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true upgrade -y || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get "${DPKG_OPTIONS[@]}" -o APT::Get::Always-Include-Phased-Updates=true upgrade -y 2>&1); ERROR; }
          if [[ $ERROR_CODE != "" ]]; then return; fi
        fi
        echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get --purge autoremove -y 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" "apt-get autoclean -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" -tt "$USER"@"$IP" "$UPDATE_USER" apt-get autoclean -y 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Fedora
      elif [[ "$OS" =~ Fedora ]]; then
        echo -e "\n${OR:-}--- DNF UPGRADE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y upgrade || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y upgrade 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        echo -e "\n${OR:-}--- DNF CLEANING ---${CL:-}"
        ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -q -p "$SSH_VM_PORT" "$USER"@"$IP" dnf -y --purge autoremove 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Arch
      elif [[ "$OS" =~ Arch ]]; then
        echo -e "${OR:-}--- PACMAN UPDATE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pacman -Su --noconfirm || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" pacman -Su --noconfirm 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
        UPDATE_CHECK
      # Alpine
      elif [[ "$OS" =~ Alpine ]]; then
        echo -e "${OR:-}--- APK UPDATE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" apk -U upgrade || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" apk -U upgrade 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      # Cent OS
      elif [[ "$OS" =~ CentOS ]]; then
        echo -e "${OR:-}--- YUM UPDATE ---${CL:-}"
        ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" yum -y update || { ERROR_CODE=$?; ID=$VM; ERROR_MSG=$(ssh -tt -q -p "$SSH_VM_PORT" "$USER"@"$IP" yum -y update 2>&1); ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
        EXTRAS
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
      fi
      return
    fi
  else
    UPDATE_VM_QEMU
  fi
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
      return
    elif [[ ${OS,,} =~ ubuntu|mint|kali|debian|devuan ]]; then
      # Check Internet connection
      if ! (RUN_QEMU_COMMAND "$VM" -- bash -c "$CHECK_URL_EXE -q -c1 $CHECK_URL &>/dev/null"); then
        echo -e "${OR:-} ❌ Internet is not reachable - skip the update${CL:-}\n"
        return
      fi
      echo -e "${OR:-}--- APT UPDATE ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "apt-get update -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      echo -e "\n${OR:-}--- APT UPGRADE ---${CL:-}"
      if [[ "$INCLUDE_PHASED_UPDATES" != "true" ]]; then
        RUN_QEMU_COMMAND "$VM" --timeout 120 -- bash -c "apt-get $DPKG_OPTIONS_STRING upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      else
        RUN_QEMU_COMMAND "$VM" --timeout 120 -- bash -c "apt-get $DPKG_OPTIONS_STRING -o APT::Get::Always-Include-Phased-Updates=true upgrade -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
        if [[ $ERROR_CODE != "" ]]; then return; fi
      fi
      echo -e "\n${OR:-}--- APT CLEANING ---${CL:-}"
      RUN_QEMU_COMMAND "$VM" -- bash -c "apt-get --purge autoremove -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
      if [[ $ERROR_CODE != "" ]]; then return; fi
      RUN_QEMU_COMMAND "$VM" -- bash -c "apt-get autoclean -y" || { ERROR_CODE=$?; ID=$VM; ERROR_MSG="$QEMU_EXEC_OUTPUT"; ERROR; }
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
    fi
  else
    echo -e "${RD:-}  ❌ ${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}${CL:-}\n\
  ${OR:-}If you want to update VMs, you must set up it by yourself!${CL:-}\n\
  For ssh (harder, but nicer output), check this: <https://github.com/BassT23/Proxmox/blob/$BRANCH/ssh.md>\n\
  For QEMU (easy connection), check this: <https://pve.proxmox.com/wiki/Qemu-guest-agent>\n"
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="${QGA_ERROR:-SSH or QEMU guest agent is not initialized on VM $VM}"
    ERROR
  fi
  CVM=""
}

UPDATE_VM_QEMU_WINDOWS () {
  local encoded result marker update_status processed reboot message

  if ! declare -f WINDOWS_POWERSHELL_ENCODE >/dev/null 2>&1; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Windows update helper is not installed"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  if ! encoded=$(WINDOWS_POWERSHELL_ENCODE install); then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Could not encode the Windows Update PowerShell command"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  echo -e "${OR:-}--- WINDOWS UPDATE ---${CL:-}"
  QEMU_GUEST_EXEC "$VM" --timeout 180 -- powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$encoded"
  if [[ $QEMU_EXEC_TRANSPORT_RC -ne 0 || "$QEMU_EXEC_EXITCODE" -ne 0 ]]; then
    ERROR_CODE=${QEMU_EXEC_EXITCODE:-1}
    ID=$VM
    ERROR_MSG="${QEMU_EXEC_OUTPUT:-Windows Update command failed}"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  result=$(printf '%s\n' "$QEMU_EXEC_STDOUT" | tr -d '\r' | tail -n 1)
  # shellcheck disable=SC2034
  IFS='|' read -r marker update_status processed reboot message <<< "$result"
  if [[ "$marker" != UU_WINDOWS || "$update_status" != ok || ! "$processed" =~ ^[0-9]+$ || ("$reboot" != true && "$reboot" != false) ]]; then
    ERROR_CODE=1
    ID=$VM
    ERROR_MSG="Invalid Windows Update response: $result"
    declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" failed "$ERROR_CODE" || true
    ERROR
    return
  fi

  echo "Windows updates processed: $processed"
  declare -f STATUS_MODEL_UPDATE_RESULT >/dev/null 2>&1 && STATUS_MODEL_UPDATE_RESULT "$VM" success 0 || true
  if [[ "$reboot" == true ]]; then
    echo -e "${OR:-}Reboot required; no automatic reboot was performed.${CL:-}"
  fi
}

## General ##
READ_CONFIG

# Debug
DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' $CONFIG_FILE)
if [[ "$DEBUG" == true ]]; then
  set -x
fi

# Logging
OUTPUT_TO_FILE () {
  echo 'EXEC_HOST="'"$HOSTNAME"'"' > /etc/ultimate-updater/temp/exec_host
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
  if [[ "${CCONTAINER:-}" == true && "${ID:-}" =~ ^[0-9]+$ ]] &&
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
  if [[ "$command_rc" -ne 0 || "$UPDATE_FAILURE" == true || "$SAFETY_FAILURE" == true ]]; then
    return 1
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
    if status_notification=$(STATUS_MODEL_RENDER_NOTIFICATION "$LOCAL_FILES/status.json" update 2>/dev/null) &&
      [[ "$status_notification" == STATE=* ]]; then
      status_body=${status_notification#*$'\n'}
      printf '%s\n' "$status_body"
      return 0
    fi
  fi
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
    printf '✅ Update erfolgreich\n'
    [[ -n "$package_count" ]] && printf '⬆️ %s\n' "$package_count"
  else
    printf '⚠️ Update fehlgeschlagen\n'
    printf 'Exitcode: %s\n' "${EXIT_CODE:-1}"
    [[ -s "$ERROR_LOG_FILE" ]] && sed -n '1,4p' "$ERROR_LOG_FILE"
  fi
  if grep -Eqi 'reboot required|reboot needed' "$LOG_FILE" 2>/dev/null; then
    printf '🔄 Neustart erforderlich\n'
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
  if [[ -f "/etc/ultimate-updater/temp/exec_host" ]]; then
    EXEC_HOST=$(awk -F'"' '/^EXEC_HOST=/ {print $2}' /etc/ultimate-updater/temp/exec_host)
  fi
  if [[ "$WELCOME_SCREEN" == true && -n "$EXEC_HOST" ]]; then
    scp "$LOCAL_FILES"/check-output "$EXEC_HOST":"$LOCAL_FILES"/check-output
  fi
  # Exit without echo
  if [[ "$EXIT_CODE" == 2 ]]; then
    exit
  # Update Finish
  elif [[ "$EXIT_CODE" == 0 ]]; then
    if [[ "$RICM" != true ]]; then
      if [[ -f $ERROR_LOG_FILE && -s $ERROR_LOG_FILE ]]; then
        echo -e "${OR:-}❌ Finished, with errors.${CL:-}\n"
        echo -e "Please checkout $ERROR_LOG_FILE"
        echo
        CLEAN_LOGFILE
        if [[ "${SELF_UPDATE_RUN:-false}" != true ]]; then
          UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" 2>/dev/null || true
        fi
      else
        if [[ "$SCRIPT_ONLY_RUN" == true ]]; then
          echo -e "${GN:-}✅ Finished, all configured script-only updates done.${CL:-}\n"
        else
          echo -e "${GN:-}✅ Finished, all updates done.${CL:-}\n"
        fi
        "$LOCAL_FILES/exit/passed.sh"
        CLEAN_LOGFILE
        if [[ "$EMAIL_ONLY_ERROR" != true ]]; then
          if [[ "${SELF_UPDATE_RUN:-false}" != true ]]; then
            UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater" "$EMAIL_USER" 2>/dev/null || true
          fi
        fi
      fi
    fi
  else
  # Update Error
    if [[ "$RICM" != true ]]; then
      echo -e "${RD:-}⚠  Error during update --- Exit Code: $EXIT_CODE${CL:-}\n"
      "$LOCAL_FILES/exit/error.sh"
      CLEAN_LOGFILE
      if [[ "${SELF_UPDATE_RUN:-false}" != true ]]; then
        UPDATE_MAIL_BODY | mail -a 'Content-Type: text/plain; charset=UTF-8' -a 'Content-Transfer-Encoding: 8bit' -r "$EMAIL_SENDER" -s "Ultimate Updater summary - $HOSTNAME" "$EMAIL_USER" 2>/dev/null
      fi
    fi
  fi
  sleep 3
  rm -rf /etc/ultimate-updater/temp/var
  rm -rf "$LOCAL_FILES"/update
  if [[ -f "/etc/ultimate-updater/temp/exec_host" && "$HOSTNAME" != "$EXEC_HOST" ]]; then rm -rf "$LOCAL_FILES"; fi
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
if ! [[ -d "/etc/ultimate-updater/temp" ]]; then mkdir /etc/ultimate-updater/temp; fi
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

# Run without commands (Automatic Mode)
if [[ "$COMMAND" != true ]]; then
  TAG_LOG=true
  HEADER_INFO
  if [[ $EXIT_ON_ERROR == false ]]; then echo -e "ℹ ${OR:-} Exit, if error come up, is disabled${CL:-}\n"; fi
  if [[ "$MODE" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    echo -e "🔄${GN:-} Updating Host${CL:-} : ${GN:-}$IP | ($HOSTNAME)${CL:-}\n"
    if [[ "$WITH_HOST" == true ]]; then
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

if ! UPDATE_FINAL_RC 0; then
  exit 1
fi

exit 0
