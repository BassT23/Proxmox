#!/bin/bash

##############
# Config Lib #
##############

READ_CONFIG() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    echo "Run the installer first: bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh)" >&2
    exit 1
  fi

  _cfg() { awk -F'"' "/^${1}=/ {print \$2}" "${CONFIG_FILE}"; }

  LOG_FILE=$(_cfg LOG_FILE)
  ERROR_LOG_FILE=$(_cfg ERROR_LOG_FILE)
  CHECK_VERSION=$(_cfg VERSION_CHECK)
  CHECK_URL=$(_cfg URL_FOR_INTERNET_CHECK)
  CHECK_URL_EXE=$(_cfg EXE_FOR_INTERNET_CHECK)
  CHECK_URL_EXE="${CHECK_URL_EXE:-ping}"
  SSH_PORT=$(_cfg SSH_PORT)
  EXIT_ON_ERROR=$(_cfg EXIT_ON_ERROR)
  WITH_HOST=$(_cfg WITH_HOST)
  WITH_LXC=$(_cfg WITH_LXC)
  WITH_VM=$(_cfg WITH_VM)
  RUNNING_CONTAINER=$(_cfg RUNNING_CONTAINER)
  STOPPED_CONTAINER=$(_cfg STOPPED_CONTAINER)
  RUNNING_VM=$(_cfg RUNNING_VM)
  STOPPED_VM=$(_cfg STOPPED_VM)
  FREEBSD_UPDATES=$(_cfg FREEBSD_UPDATES)
  SNAPSHOT=$(_cfg SNAPSHOT)
  KEEP_SNAPSHOT=$(_cfg KEEP_SNAPSHOTS)
  BACKUP=$(_cfg BACKUP)
  BACKUP_LXC_MP=$(_cfg BACKUP_LXC_MP)
  BACKUP_MODE=$(_cfg BACKUP_MODE)
  LXC_START_DELAY=$(_cfg LXC_START_DELAY)
  VM_START_DELAY=$(_cfg VM_START_DELAY)
  REEBOOT_IF_NEEDED=$(_cfg REEBOOT_IF_NEEDED)
  EXTRA_GLOBAL=$(_cfg EXTRA_GLOBAL)
  EXTRA_IN_HEADLESS=$(_cfg IN_HEADLESS_MODE)
  EXCLUDED=$(_cfg EXCLUDE)
  ONLY=$(_cfg ONLY)
  INCLUDE_PHASED_UPDATES=$(_cfg INCLUDE_PHASED_UPDATES)
  INCLUDE_FSTRIM=$(_cfg INCLUDE_FSTRIM)
  FSTRIM_WITH_MOUNTPOINT=$(_cfg FSTRIM_WITH_MOUNTPOINT)
  CLEAN_APT_CACHE=$(_cfg CLEAN_APT_CACHE)
  PACMAN_ENVIRONMENT=$(_cfg PACMAN_ENVIRONMENT)
  EMAIL_USER=$(_cfg EMAIL_USER)
  EMAIL_NO_UPDATES=$(_cfg EMAIL_NO_UPDATES)

  declare -f apply_only_exclude_tags >/dev/null 2>&1 && apply_only_exclude_tags ONLY EXCLUDED
}

# CONFIG_WIZARD — interactive configuration editor.
# Prompts the user for each setting; pressing Enter keeps the current value.
CONFIG_WIZARD() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Config file not found: ${CONFIG_FILE}" >&2
    exit 1
  fi

  READ_CONFIG

  echo ""
  echo "=== The Ultimate Updater — Configuration Wizard ==="
  echo "    Press Enter to keep the current value."
  echo "    Valid boolean values: true / false"
  echo ""

  _ask_bool() {
    local key="$1" desc="$2"
    local current="${!key:-false}"
    local val
    read -rp "  ${desc} [${current}]: " val
    val="${val:-${current}}"
    if [[ ! "${val}" =~ ^(true|false)$ ]]; then
      echo "    Invalid value — keeping: ${current}"
      val="${current}"
    fi
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${CONFIG_FILE}"
  }

  _ask_str() {
    local key="$1" desc="$2"
    local current="${!key:-}"
    local val
    read -rp "  ${desc} [${current}]: " val
    val="${val:-${current}}"
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${CONFIG_FILE}"
  }

  _ask_int() {
    local key="$1" desc="$2"
    local current="${!key:-0}"
    local val
    read -rp "  ${desc} [${current}]: " val
    val="${val:-${current}}"
    if [[ ! "${val}" =~ ^[0-9]+$ ]]; then
      echo "    Invalid value — keeping: ${current}"
      val="${current}"
    fi
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "${CONFIG_FILE}"
  }

  echo "--- What to update ---"
  _ask_bool "WITH_HOST"  "Update Proxmox host itself"
  _ask_bool "WITH_LXC"   "Update LXC containers"
  _ask_bool "WITH_VM"    "Update VMs"
  echo ""

  echo "--- Container / VM behaviour ---"
  _ask_bool "STOPPED_CONTAINER"  "Start stopped containers to update them"
  _ask_bool "RUNNING_CONTAINER"  "Update running containers"
  _ask_bool "STOPPED_VM"         "Start stopped VMs to update them"
  _ask_bool "RUNNING_VM"         "Update running VMs"
  _ask_bool "REEBOOT_IF_NEEDED"  "Reboot after update if reboot is required"
  _ask_bool "FREEBSD_UPDATES"    "Update FreeBSD VMs"
  _ask_bool "INCLUDE_PHASED_UPDATES" "Include phased APT updates"
  echo ""

  echo "--- Snapshot / Backup ---"
  _ask_bool "SNAPSHOT"       "Create snapshot before each update"
  _ask_int  "KEEP_SNAPSHOTS" "Number of update snapshots to keep"
  _ask_bool "BACKUP"         "Create backup before each update"
  _ask_bool "BACKUP_LXC_MP"  "Use backup when snapshot is blocked by mount points"
  _ask_str  "BACKUP_MODE"    "Backup mode: stop / suspend / snapshot"
  echo ""

  echo "--- Extras / Plugins ---"
  _ask_bool "EXTRA_GLOBAL"     "Enable extra updates (plugins)"
  _ask_bool "IN_HEADLESS_MODE" "Run plugins in headless mode"
  echo ""

  echo "--- Filesystem ---"
  _ask_bool "INCLUDE_FSTRIM"         "Run fstrim after updates"
  _ask_bool "FSTRIM_WITH_MOUNTPOINT" "Include mount points in fstrim"
  _ask_bool "CLEAN_APT_CACHE"        "Run apt-get clean after updates (removes all cached .debs)"
  echo ""

  echo "--- Notifications ---"
  _ask_str  "EMAIL_USER"        "Email address to notify"
  _ask_bool "EMAIL_NO_UPDATES"  "Send email even when no updates are found"
  echo ""

  echo "--- Error handling ---"
  _ask_bool "EXIT_ON_ERROR" "Stop the entire run on first error"
  echo ""

  echo "Configuration saved to ${CONFIG_FILE}"
  echo ""
}
