#!/bin/bash

##########
# Update #
##########

VERSION="5.0.0"

LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="${LOCAL_FILES}/update.conf"
USER_SCRIPTS="${LOCAL_FILES}/scripts.d"
BRANCH=$(awk -F'"' '/^USED_BRANCH=/ {print $2}' "${CONFIG_FILE}" 2>/dev/null || echo "master")
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/${BRANCH}"

# Source libraries
# shellcheck source=lib/ui.sh
source "${LOCAL_FILES}/lib/ui.sh"
# shellcheck source=lib/errors.sh
source "${LOCAL_FILES}/lib/errors.sh"
# shellcheck source=lib/os-update.sh
source "${LOCAL_FILES}/lib/os-update.sh"
# shellcheck source=lib/snapshot.sh
source "${LOCAL_FILES}/lib/snapshot.sh"
# shellcheck source=lib/config.sh
source "${LOCAL_FILES}/lib/config.sh"
# shellcheck source=tag-filter.sh
source "${LOCAL_FILES}/tag-filter.sh"


# ==============================================================================
# Core checks
# ==============================================================================

CHECK_ROOT() {
  if [[ "${RICM:-false}" != true && "${EUID}" -ne 0 ]]; then
    echo -e "\n${RD}  Please run this as root.${CL}\n"
    exit 2
  fi
}

CHECK_INTERNET() {
  local exe="${CHECK_URL_EXE:-ping}"
  local url="${CHECK_URL:-google.com}"
  if ! "${exe}" -q -c1 "${url}" &>/dev/null; then
    echo -e "\n${OR}  No internet — cannot update.${CL}\n"
    exit 2
  fi
}


# ==============================================================================
# Version check / self-update
# ==============================================================================

VERSION_CHECK() {
  local tmp="${LOCAL_FILES}/temp"
  mkdir -p "${tmp}"

  curl -sf "https://raw.githubusercontent.com/BassT23/Proxmox/master/update.sh"  > "${tmp}/update_master.sh"
  curl -sf "https://raw.githubusercontent.com/BassT23/Proxmox/beta/update.sh"    > "${tmp}/update_beta.sh"
  curl -sf "https://raw.githubusercontent.com/BassT23/Proxmox/develop/update.sh" > "${tmp}/update_develop.sh"

  local master_ver beta_ver develop_ver local_ver
  master_ver=$(awk  -F'"' '/^VERSION=/ {print $2}' "${tmp}/update_master.sh")
  beta_ver=$(awk    -F'"' '/^VERSION=/ {print $2}' "${tmp}/update_beta.sh")
  develop_ver=$(awk -F'"' '/^VERSION=/ {print $2}' "${tmp}/update_develop.sh")
  local_ver=$(awk   -F'"' '/^VERSION=/ {print $2}' "${LOCAL_FILES}/update.sh")

  rm -f "${tmp}/update_master.sh" "${tmp}/update_beta.sh" "${tmp}/update_develop.sh"

  local newer=""
  case "${BRANCH}" in
    develop)
      echo -e "${OR}On develop branch${CL}"
      [[ "${local_ver}" < "${master_ver}" ]]   && newer="master (${master_ver})"
      [[ -z "${newer}" && "${local_ver}" < "${beta_ver}" ]]    && newer="beta (${beta_ver})"
      [[ -z "${newer}" && "${local_ver}" < "${develop_ver}" ]] && newer="develop (${develop_ver})"
      ;;
    beta)
      echo -e "${OR}On beta branch${CL}"
      [[ "${local_ver}" < "${master_ver}" ]] && newer="master (${master_ver})"
      [[ -z "${newer}" && "${local_ver}" < "${beta_ver}" ]] && newer="beta (${beta_ver})"
      ;;
    *)
      [[ "${local_ver}" < "${master_ver}" ]] && newer="master (${master_ver})"
      ;;
  esac

  if [[ -n "${newer}" ]]; then
    echo -e "${OR}A newer version is available — ${newer}${CL}"
    echo -e "  Installed: ${local_ver}"
    if [[ "${HEADLESS:-false}" != true ]]; then
      read -rp "Update The Ultimate Updater first? [Y/y/Enter = yes]: " _reply
      if [[ "${_reply}" =~ ^[Yy]$ || "${_reply}" == "" ]]; then
        bash <(curl -s "${SERVER_URL}/install.sh") update
      fi
    fi
  else
    echo -e "${GN}The Ultimate Updater is up to date (${local_ver})${CL}"
  fi
  echo
}

UPDATE() {
  read -rp "Update to ${BRANCH} branch? [Y/y/Enter = yes]: " _reply
  if [[ "${_reply}" =~ ^[Yy]$ || "${_reply}" == "" ]]; then
    bash <(curl -s "https://raw.githubusercontent.com/BassT23/Proxmox/${BRANCH}/install.sh") update
  fi
  exit 2
}

UNINSTALL() {
  echo -e "\n${OR}Uninstall The Ultimate Updater${CL}\n"
  echo -e "${RD}This will remove all installed files. Continue?${CL}"
  read -rp "Type Y/y to confirm: " _reply
  if [[ "${_reply}" =~ ^[Yy]$ ]]; then
    bash <(curl -s "${SERVER_URL}/install.sh") uninstall
  fi
  exit 2
}

STATUS() {
  local tmp="${LOCAL_FILES}/temp"
  mkdir -p "${tmp}"

  curl -sf "${SERVER_URL}/update.sh"       > "${tmp}/update.sh"
  curl -sf "${SERVER_URL}/update.conf"     > "${tmp}/update.conf"

  local sv sc lv lc
  sv=$(awk -F'"' '/^VERSION=/ {print $2}' "${tmp}/update.sh")
  sc=$(awk -F'"' '/^VERSION=/ {print $2}' "${tmp}/update.conf")
  lv=$(awk -F'"' '/^VERSION=/ {print $2}' "${LOCAL_FILES}/update.sh")
  lc=$(awk -F'"' '/^VERSION=/ {print $2}' "${LOCAL_FILES}/update.conf")

  local last_mod
  last_mod=$(curl -sf "https://api.github.com/repos/BassT23/Proxmox" \
    | grep pushed_at | cut -d: -f2- | tr -d '" ' | sed 's/,//')

  echo -e "Last GitHub push: ${last_mod}\n"
  [[ "${BRANCH}" != master ]] && echo -e "${OR}Branch: ${BRANCH}${CL}"
  echo -e "  Updater: $([[ "${lv}" == "${sv}" ]] && echo "${GN}${lv}${CL}" || echo "${lv} / ${OR}${sv}${CL}")"
  echo -e "  Config:  $([[ "${lc}" == "${sc}" ]] && echo "${GN}${lc}${CL}" || echo "${lc} / ${OR}${sc}${CL}")"

  if [[ "${WELCOME_SCREEN:-false}" == true ]]; then
    curl -sf "${SERVER_URL}/welcome-screen.sh" > "${tmp}/welcome-screen.sh"
    curl -sf "${SERVER_URL}/check-updates.sh"  > "${tmp}/check-updates.sh"
    local sw sch lw lch
    sw=$(awk  -F'"' '/^VERSION=/ {print $2}' "${tmp}/welcome-screen.sh")
    sch=$(awk -F'"' '/^VERSION=/ {print $2}' "${tmp}/check-updates.sh")
    lw=$(awk  -F'"' '/^VERSION=/ {print $2}' /etc/update-motd.d/01-welcome-screen 2>/dev/null || echo "n/a")
    lch=$(awk -F'"' '/^VERSION=/ {print $2}' "${LOCAL_FILES}/check-updates.sh")
    echo -e "  Welcome: $([[ "${lw}"  == "${sw}"  ]] && echo "${GN}${lw}${CL}"  || echo "${lw} / ${OR}${sw}${CL}")"
    echo -e "  Checker: $([[ "${lch}" == "${sch}" ]] && echo "${GN}${lch}${CL}" || echo "${lch} / ${OR}${sch}${CL}")"
  fi

  echo
  rm -rf "${tmp:?}"/*
  exit 2
}


# ==============================================================================
# CLI
# ==============================================================================

USAGE() {
  cat <<EOF

Usage: update [OPTIONS] [COMMAND]

Commands:
  host                 Update this host, all containers, and all VMs
  cluster              Update all cluster nodes
  <VMID>               Update a single container or VM by ID

  status               Show version status (local vs server)
  --config             Run the interactive configuration wizard
  uninstall            Uninstall The Ultimate Updater

Self-update:
  master  -up          Update to the latest stable release
  beta    -up          Update to the beta branch
  develop -up          Update to the develop branch

Options:
  -s, --silent         Headless mode (no interactive prompts)
  -v, --version        Show version information
  -h, --help           Show this help message
  -dist-upgrade        Run Debian distribution upgrade on all containers
  -check               Run the update checker (welcome screen data)

Report issues: https://github.com/BassT23/Proxmox/issues

EOF
}

ARGUMENTS() {
  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "${arg}" in
      [0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9])
        COMMAND=true
        SINGLE_UPDATE=true
        MODE=" Single"
        ONLY="${arg}"
        HEADER_INFO
        [[ "${EXIT_ON_ERROR:-false}" == false ]] && ui_info "Continue-on-error enabled"
        ui_info "Updating only LXC/VM ${arg} (host mode only)"
        CONTAINER_UPDATE_START
        VM_UPDATE_START
        ;;
      -h|--help)    USAGE; exit 0 ;;
      -v|--version) VERSION_CHECK; exit 0 ;;
      -s|--silent)  HEADLESS=true ;;
      -c)           RICM=true ;;
      -w)           WELCOME_SCREEN=true ;;
      --config)
        COMMAND=true
        CONFIG_WIZARD
        exit 0
        ;;
      host)
        COMMAND=true
        TAG_LOG=true
        if [[ "${RICM:-false}" != true ]]; then
          MODE="  Host "
          HEADER_INFO
          [[ "${EXIT_ON_ERROR:-false}" == false ]] && ui_info "Continue-on-error enabled"
        fi
        ui_update "Updating host: ${IP} (${HOSTNAME})"
        [[ "${WITH_HOST:-true}" == true ]] && UPDATE_HOST_ITSELF      || ui_skip "Host update disabled"
        [[ "${WITH_LXC:-true}"  == true ]] && CONTAINER_UPDATE_START  || ui_skip "Container updates disabled"
        [[ "${WITH_VM:-true}"   == true ]] && VM_UPDATE_START         || ui_skip "VM updates disabled"
        ;;
      cluster)
        COMMAND=true
        MODE="Cluster"
        HEADER_INFO
        HOST_UPDATE_START
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        ;;
      master|beta|develop)
        if [[ "$2" != "-up" ]]; then
          echo -e "${OR}Usage: update ${arg} -up${CL}"
          exit 2
        fi
        BRANCH="${arg}"
        BRANCH_SET=true
        ;;
      -up)
        COMMAND=true
        [[ "${BRANCH_SET:-false}" != true ]] && BRANCH=master
        UPDATE
        ;;
      -dist-upgrade)
        INFO=false
        HEADER_INFO
        COMMAND=true
        CHECK_DIST=true
        CONTAINER_UPDATE_START
        exit 2
        ;;
      -check)
        "${LOCAL_FILES}/check-updates.sh"
        exit 2
        ;;
      status)
        INFO=false
        HEADER_INFO
        COMMAND=true
        STATUS
        ;;
      *)
        echo -e "\n${RD}Unknown argument: ${arg}${CL}"
        USAGE
        exit 2
        ;;
    esac
    shift
  done
}


# ==============================================================================
# User scripts
# ==============================================================================

USER_SCRIPTS_LXC() {
  local dir="${USER_SCRIPTS}/${CONTAINER}"
  [[ -d "${dir}" ]] || return 0
  echo ""
  echo "--- Running user scripts ---"
  pct exec "${CONTAINER}" -- bash -c "mkdir -p ${LOCAL_FILES}/user-scripts"
  for script in "${dir}"/*; do
    local name
    name=$(basename "${script}")
    pct push "${CONTAINER}" -- "${script}" "${LOCAL_FILES}/user-scripts/${name}"
    pct exec "${CONTAINER}" -- bash -c \
      "chmod +x ${LOCAL_FILES}/user-scripts/${name} && ${LOCAL_FILES}/user-scripts/${name}"
  done
  pct exec "${CONTAINER}" -- bash -c "rm -rf ${LOCAL_FILES} || true"
  echo "--- User scripts done ---"
}

USER_SCRIPTS_VM() {
  local dir="${USER_SCRIPTS}/${VM}"
  [[ -d "${dir}" ]] || return 0
  echo ""
  echo "--- Running user scripts ---"
  ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" "mkdir -p ${LOCAL_FILES}/user-scripts/"
  for script in "${dir}"/*; do
    local name
    name=$(basename "${script}")
    scp "${script}" "${IP}:${LOCAL_FILES}/user-scripts/${name}"
    ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" \
      "chmod +x ${LOCAL_FILES}/user-scripts/${name} && ${LOCAL_FILES}/user-scripts/${name}"
  done
  ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" "rm -rf ${LOCAL_FILES} || true"
  echo "--- User scripts done ---"
}


# ==============================================================================
# Plugin runner (extras)
# ==============================================================================

EXTRAS() {
  if [[ "${EXTRA_GLOBAL:-true}" != true ]]; then
    ui_skip "Extra updates disabled"
    return 0
  fi
  if [[ "${HEADLESS:-false}" == true && "${EXTRA_IN_HEADLESS:-false}" == false ]]; then
    ui_skip "Extra updates skipped in headless mode"
    return 0
  fi

  local plugin_dir="${LOCAL_FILES}/plugins"
  [[ -d "${plugin_dir}" ]] || return 0

  ui_section "Extra updates"

  if [[ "${SSH_CONNECTION:-false}" != true ]]; then
    # LXC container path
    pct exec "${CONTAINER}" -- bash -c "mkdir -p ${LOCAL_FILES}/plugins"
    for plugin in "${plugin_dir}"/*.sh; do
      [[ -f "${plugin}" ]] || continue
      pct push "${CONTAINER}" -- "${plugin}" "${LOCAL_FILES}/plugins/$(basename "${plugin}")"
    done
    pct push "${CONTAINER}" -- "${LOCAL_FILES}/run-plugins.sh" "${LOCAL_FILES}/run-plugins.sh"
    pct push "${CONTAINER}" -- "${LOCAL_FILES}/update.conf"    "${LOCAL_FILES}/update.conf"
    pct exec "${CONTAINER}" -- bash -c \
      "chmod +x ${LOCAL_FILES}/run-plugins.sh && \
       ${LOCAL_FILES}/run-plugins.sh && \
       rm -rf ${LOCAL_FILES} || true"
    USER_SCRIPTS_LXC
  elif [[ "${SSH_USER:-root}" != root ]]; then
    ui_warn "Root SSH required for extra updates — skipping"
  else
    # VM via SSH
    ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" "mkdir -p ${LOCAL_FILES}/plugins"
    for plugin in "${plugin_dir}"/*.sh; do
      [[ -f "${plugin}" ]] || continue
      scp "${plugin}" "${IP}:${LOCAL_FILES}/plugins/$(basename "${plugin}")"
    done
    scp "${LOCAL_FILES}/run-plugins.sh" "${IP}:${LOCAL_FILES}/run-plugins.sh"
    scp "${LOCAL_FILES}/update.conf"    "${IP}:${LOCAL_FILES}/update.conf"
    ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" \
      "chmod +x ${LOCAL_FILES}/run-plugins.sh && \
       ${LOCAL_FILES}/run-plugins.sh && \
       rm -rf ${LOCAL_FILES} || true"
    USER_SCRIPTS_VM
  fi

  ui_ok "Extra updates done"
}


# ==============================================================================
# Filesystem trim
# ==============================================================================

TRIM_FILESYSTEM() {
  [[ "${INCLUDE_FSTRIM:-false}" == true ]] || return 0

  local root_fs
  root_fs=$(df -Th "/" | awk 'NR==2 {print $2}')
  local lvs_before
  mapfile -t lvs_before < <(lvs 2>/dev/null \
    | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-${CONTAINER}"'/) {gsub(/%/, "", $7); print $7}')

  if [[ ${#lvs_before[@]} -gt 0 && "${root_fs}" == ext4 ]]; then
    ui_section "Filesystem trim"
    echo "Before: ${lvs_before[*]}%"
    pct fstrim "${CONTAINER}" --ignore-mountpoints "${FSTRIM_WITH_MOUNTPOINT:-true}"
    local lvs_after
    mapfile -t lvs_after < <(lvs 2>/dev/null \
      | awk -F '[[:space:]]+' 'NR>1 && (/Data%|'"vm-${CONTAINER}"'/) {gsub(/%/, "", $7); print $7}')
    echo "After:  ${lvs_after[*]}%"
    sleep 1
  fi
}


# ==============================================================================
# Distribution upgrade
# ==============================================================================

DIST_UPGRADE() {
  local deb_version
  deb_version=$(pct exec "${CONTAINER}" -- bash -c \
    "grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '\"'")

  if [[ "${deb_version}" != 12 ]]; then
    ui_skip "No Debian 12 found (detected: ${deb_version:-unknown})"
    return 0
  fi

  echo -e "${OR}Debian 12 detected. Upgrade to Debian 13 (Trixie)?${CL}"
  read -rp "Type Y/y to confirm: " _reply
  [[ "${_reply}" =~ ^[Yy]$ ]] || { ui_skip "Distribution upgrade skipped"; return 0; }

  SNAPSHOT=
  BACKUP=true
  CONTAINER_BACKUP || return 1

  ui_section "APT update"
  pct exec "${CONTAINER}" -- bash -c "apt-get update -y"
  ui_section "APT dist-upgrade"
  pct exec "${CONTAINER}" -- bash -c "apt-get dist-upgrade -y"
  ui_section "Cleanup"
  pct exec "${CONTAINER}" -- bash -c "apt-get --purge autoremove -y && apt-get autoclean -y"

  local free_gb
  free_gb=$(pct exec "${CONTAINER}" -- bash -c \
    "df --output=avail -BG / | tail -1 | sed 's/G//'")
  if [[ "${free_gb}" -lt 5 ]]; then
    ui_error "Not enough disk space (need 5 GB free). Resize and retry."
    exit 100
  fi

  echo -e "${OR}This will update APT sources to Trixie and run the upgrade.${CL}"
  echo "After completion, verify your sources with: sudo apt modernize-sources"
  read -rp "Type Y/y to continue: " _reply
  [[ "${_reply}" =~ ^[Yy]$ ]] || { ui_skip "Upgrade cancelled"; return 0; }

  pct exec "${CONTAINER}" -- bash -c \
    "sed -i 's/bookworm/trixie/g' /etc/apt/sources.list && \
     find /etc/apt/sources.list.d -type f -exec sed -i 's/bookworm/trixie/g' {} \;"
  ui_section "APT update (Trixie)"
  pct exec "${CONTAINER}" -- bash -c "apt-get update -y"
  ui_section "APT dist-upgrade (Trixie)"
  pct exec "${CONTAINER}" -- bash -c "apt-get dist-upgrade -y"
  ui_ok "Upgrade to Debian 13 (Trixie) complete"
  pct exec "${CONTAINER}" -- bash -c "reboot"
}


# ==============================================================================
# Update checker (welcome screen data)
# ==============================================================================

UPDATE_CHECK() {
  [[ "${WELCOME_SCREEN:-false}" == true ]] || { echo; return 0; }

  ui_section "Updating welcome screen data"
  if [[ "${CHOST:-false}" == true ]]; then
    "${LOCAL_FILES}/check-updates.sh" -u chost | tee -a "${LOCAL_FILES}/check-output"
  elif [[ "${CCONTAINER:-false}" == true ]]; then
    "${LOCAL_FILES}/check-updates.sh" -u ccontainer | tee -a "${LOCAL_FILES}/check-output"
  elif [[ "${CVM:-false}" == true ]]; then
    ssh -q -p "${SSH_PORT:-22}" "${HOSTNAME}" \
      "\"${LOCAL_FILES}/check-updates.sh\" -u cvm" | tee -a "${LOCAL_FILES}/check-output"
  fi
}


# ==============================================================================
# Boot wait helpers
# ==============================================================================

WAIT_FOR_BOOTUP_LXC() {
  local count=1 max=10
  sleep "${LXC_START_DELAY:-5}"
  while [[ ${count} -le ${max} ]]; do
    if pct exec "${CONTAINER}" -- bash -c "exit" >/dev/null 2>&1; then
      ui_ok "${CONTAINER} reachable (attempt ${count})"
      return 0
    fi
    ui_info "Attempt ${count}/${max} — waiting"
    sleep "${LXC_START_DELAY:-5}"
    (( count++ ))
  done
  ui_error "Could not reach ${CONTAINER} after ${max} attempts"
}

WAIT_FOR_BOOTUP_SSH() {
  local count=1 max=10
  sleep "${SSH_START_DELAY_TIME:-45}"
  while [[ ${count} -le ${max} ]]; do
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q \
        -p "${SSH_VM_PORT:-22}" "${SSH_USER:-root}@${IP}" exit >/dev/null 2>&1; then
      ui_ok "VM ${VM} reachable via SSH (attempt ${count})"
      return 0
    fi
    ui_info "Attempt ${count}/${max} — waiting"
    sleep "${SSH_START_DELAY_TIME:-45}"
    (( count++ ))
  done
  ui_error "Could not reach VM ${VM} via SSH after ${max} attempts"
}


# ==============================================================================
# Host
# ==============================================================================

HOST_UPDATE_START() {
  [[ "${RICM:-false}" != true ]] && true > "${LOCAL_FILES}/check-output"
  for host in ${HOSTS}; do
    if ssh -q -p "${SSH_PORT:-22}" "${host}" test >/dev/null 2>&1; [ $? -eq 255 ]; then
      ui_skip "Host ${host} unreachable"
    else
      UPDATE_HOST "${host}"
    fi
  done
}

UPDATE_HOST() {
  local host="$1"
  local start_host
  start_host=$(hostname -i | cut -d' ' -f1)

  if [[ "${host}" != "${start_host}" ]]; then
    ssh -q -p "${SSH_PORT:-22}" "${host}" mkdir -p "${LOCAL_FILES}/temp"
    scp "$0"                                     "${host}:${LOCAL_FILES}/update"
    scp "${LOCAL_FILES}/update.conf"             "${host}:${LOCAL_FILES}/update.conf"
    scp "${LOCAL_FILES}/run-plugins.sh"          "${host}:${LOCAL_FILES}/run-plugins.sh"
    scp -r "${LOCAL_FILES}/lib/"                 "${host}:${LOCAL_FILES}/"
    scp -r "${LOCAL_FILES}/plugins/"             "${host}:${LOCAL_FILES}/"
    scp -r "${LOCAL_FILES}/VMs/"                 "${host}:${LOCAL_FILES}/"
    [[ -f "${LOCAL_FILES}/tag-filter.sh" ]] && \
      scp "${LOCAL_FILES}/tag-filter.sh"         "${host}:${LOCAL_FILES}/tag-filter.sh"
    if [[ "${WELCOME_SCREEN:-false}" == true ]]; then
      scp "${LOCAL_FILES}/check-updates.sh"      "${host}:${LOCAL_FILES}/check-updates.sh"
      scp "${LOCAL_FILES}/check-output"          "${host}:${LOCAL_FILES}/check-output" 2>/dev/null || true
    fi
    scp /etc/ultimate-updater/temp/exec_host     "${host}:/etc/ultimate-updater/temp/" 2>/dev/null || true
  fi

  local flags="-c"
  [[ "${HEADLESS:-false}" == true ]]       && flags="${flags} -s"
  [[ "${WELCOME_SCREEN:-false}" == true ]] && flags="${flags} -w"
  ssh -q -p "${SSH_PORT:-22}" "${host}" 'bash -s' < "$0" -- "${flags} host"
}

UPDATE_HOST_ITSELF() {
  CHOST=true

  ui_section "PVE UPDATE"
  pveupdate || true

  ui_section "APT UPGRADE"
  local upgrade_cmd
  if [[ "${HEADLESS:-false}" == true ]]; then
    upgrade_cmd="DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
  elif [[ "${INCLUDE_PHASED_UPDATES:-false}" == true ]]; then
    upgrade_cmd="apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
  else
    upgrade_cmd="apt-get dist-upgrade -y"
  fi

  if ! bash -c "${upgrade_cmd}"; then
    log_error "${HOSTNAME}" "${HOSTNAME}" $? "apt-get dist-upgrade failed"
    CHOST=""
    return 1
  fi

  ui_section "APT CLEANUP"
  apt-get --purge autoremove -y || true

  CHOST=""
  UPDATE_CHECK
  CHOST=true
}


# ==============================================================================
# Containers (LXC)
# ==============================================================================

CONTAINER_UPDATE_START() {
  local containers
  containers=$(pct list | tail -n +2 | cut -f1 -d' ')

  for CONTAINER in ${containers}; do
    if [[ -z "${ONLY:-}" && "${EXCLUDED:-}" =~ ${CONTAINER} ]]; then
      ui_skip "LXC ${CONTAINER} excluded"
    elif [[ -n "${ONLY:-}" ]] && ! [[ "${ONLY}" =~ ${CONTAINER} ]]; then
      [[ "${SINGLE_UPDATE:-false}" != true ]] && ui_skip "LXC ${CONTAINER} not in selection"
      continue
    elif pct config "${CONTAINER}" | grep -q template; then
      ui_skip "LXC ${CONTAINER} is a template"
      continue
    else
      local status
      status=$(pct status "${CONTAINER}")
      if [[ "${status}" == "status: stopped" && "${STOPPED_CONTAINER:-true}" == true ]]; then
        WILL_STOP=true
        ui_start "Starting LXC ${CONTAINER}"
        pct start "${CONTAINER}"
        ui_wait "Waiting for LXC ${CONTAINER} to start"
        WAIT_FOR_BOOTUP_LXC
        UPDATE_CONTAINER "${CONTAINER}"
        ui_stop "Shutting down LXC ${CONTAINER}"
        pct shutdown "${CONTAINER}" &
        WILL_STOP=false
      elif [[ "${status}" == "status: stopped" ]]; then
        ui_skip "LXC ${CONTAINER} is stopped (STOPPED_CONTAINER=false)"
      elif [[ "${status}" == "status: running" && "${RUNNING_CONTAINER:-true}" == true ]]; then
        UPDATE_CONTAINER "${CONTAINER}"
      elif [[ "${status}" == "status: running" ]]; then
        ui_skip "LXC ${CONTAINER} is running (RUNNING_CONTAINER=false)"
      else
        ui_warn "LXC ${CONTAINER} — unknown status: ${status}"
      fi
    fi
  done

  rm -rf /etc/ultimate-updater/temp/temp
}

UPDATE_CONTAINER() {
  CONTAINER="$1"
  CCONTAINER=true
  echo "CONTAINER=\"${CONTAINER}\"" > /etc/ultimate-updater/temp/var

  local os
  os=$(pct config "${CONTAINER}" | awk '/^ostype/ {print $2}')
  _TARGET_NAME=$(pct exec "${CONTAINER}" hostname 2>/dev/null || echo "${CONTAINER}")

  if [[ "${CHECK_DIST:-false}" == true ]]; then
    ui_update "Checking dist-upgrade: LXC ${CONTAINER} (${_TARGET_NAME})"
    if [[ "${os}" =~ debian ]]; then
      DIST_UPGRADE
    else
      ui_warn "Distribution upgrade only supported for Debian"
    fi
    CCONTAINER=""
    return 0
  fi

  ui_update "Updating LXC ${CONTAINER}: ${_TARGET_NAME}"

  internet_check_on "lxc" "${CONTAINER}" || { CCONTAINER=""; return 0; }

  ui_backup "Snapshot / Backup"
  CONTAINER_BACKUP || { CCONTAINER=""; return 0; }

  run_os_update "lxc" "${CONTAINER}" "${os}"

  EXTRAS
  TRIM_FILESYSTEM
  UPDATE_CHECK
  CCONTAINER=""
}


# ==============================================================================
# VMs
# ==============================================================================

VM_UPDATE_START() {
  local vms
  vms=$(qm list | tail -n +2 | cut -c -10)

  for VM in ${vms}; do
    local pre_os
    pre_os=$(qm config "${VM}" | grep ostype || true)

    if [[ -z "${ONLY:-}" && "${EXCLUDED:-}" =~ ${VM} ]]; then
      ui_skip "VM ${VM} excluded"
    elif [[ -n "${ONLY:-}" ]] && ! [[ "${ONLY}" =~ ${VM} ]]; then
      [[ "${SINGLE_UPDATE:-false}" != true ]] && ui_skip "VM ${VM} not in selection"
      continue
    elif qm config "${VM}" | grep -q template; then
      ui_skip "VM ${VM} is a template"
      continue
    elif [[ "${pre_os}" =~ w ]]; then
      ui_skip "VM ${VM} — Windows not supported"
      continue
    else
      local status
      status=$(qm status "${VM}")
      if [[ "${status}" == "status: stopped" && "${STOPPED_VM:-true}" == true ]]; then
        if [[ $(qm config "${VM}" | grep 'agent:' | sed 's/agent:\s*//') == 1 \
              || -f "${LOCAL_FILES}/VMs/${VM}" ]]; then
          WILL_STOP=true
          ui_start "Starting VM ${VM}"
          qm start "${VM}" >/dev/null 2>&1
          START_WAITING=true
          UPDATE_VM "${VM}"
          ui_stop "Shutting down VM ${VM}"
          qm shutdown "${VM}" &
          WILL_STOP=false
          START_WAITING=false
        else
          ui_skip "VM ${VM} — no QEMU agent or SSH config found"
        fi
      elif [[ "${status}" == "status: stopped" ]]; then
        ui_skip "VM ${VM} is stopped (STOPPED_VM=false)"
      elif [[ "${status}" == "status: running" && "${RUNNING_VM:-true}" == true ]]; then
        UPDATE_VM "${VM}"
      elif [[ "${status}" == "status: running" ]]; then
        ui_skip "VM ${VM} is running (RUNNING_VM=false)"
      else
        ui_warn "VM ${VM} — unknown status: ${status}"
      fi
    fi
  done
}

UPDATE_VM() {
  VM="$1"
  CVM=true
  echo "VM=\"${VM}\"" > /etc/ultimate-updater/temp/var

  local name
  name=$(qm config "${VM}" | grep 'name:' | sed 's/name:\s*//')
  _TARGET_NAME="${name}"

  ui_update "Updating VM ${VM}: ${name}"

  ui_backup "Snapshot / Backup"
  VM_BACKUP || { CVM=""; return 0; }
  echo

  if [[ -f "${LOCAL_FILES}/VMs/${VM}" ]]; then
    IP=$(awk -F'"'        '/^IP=/             {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    SSH_USER=$(awk -F'"'  '/^USER=/           {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    SSH_VM_PORT=$(awk -F'"' '/^SSH_VM_PORT=/  {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    SSH_USER="${SSH_USER:-root}"
    SSH_VM_PORT="${SSH_VM_PORT:-22}"
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-45}"

    if [[ "${START_WAITING:-false}" == true ]]; then
      ui_wait "Waiting for VM to boot"
      WAIT_FOR_BOOTUP_SSH
    fi

    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -q \
        -p "${SSH_VM_PORT}" "${SSH_USER}@${IP}" exit >/dev/null 2>&1; then
      ui_warn "SSH unreachable — falling back to QEMU agent"
      ui_info "SSH setup guide: https://github.com/BassT23/Proxmox/blob/${BRANCH}/ssh.md"
      START_WAITING=false
      UPDATE_VM_QEMU
      CVM=""
      return 0
    fi

    SSH_CONNECTION=true

    local kernel os os_family=""
    kernel=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep kernel-version || true)
    os=$(ssh -q -p "${SSH_VM_PORT}" "${SSH_USER}@${IP}" hostnamectl 2>/dev/null | grep System || true)

    if [[ "${kernel}" =~ FreeBSD ]]; then
      if [[ "${FREEBSD_UPDATES:-false}" == true ]]; then
        pkg_upgrade "ssh" "${VM}"
      else
        ui_skip "FreeBSD — updates disabled"
      fi
      SSH_CONNECTION=""
      CVM=""
      return 0
    fi

    [[ "${os,,}" =~ debian|ubuntu|mint|kali|neon|devuan ]] && os_family="debian"
    [[ "${os,,}" =~ fedora ]]  && os_family="fedora"
    [[ "${os,,}" =~ arch ]]    && os_family="archlinux"
    [[ "${os,,}" =~ alpine ]]  && os_family="alpine"
    [[ "${os,,}" =~ centos ]]  && os_family="centos"

    internet_check_on "ssh" "${VM}" || { SSH_CONNECTION=""; CVM=""; return 0; }
    run_os_update "ssh" "${VM}" "${os_family}"
    EXTRAS
    UPDATE_CHECK
    SSH_CONNECTION=""
  else
    UPDATE_VM_QEMU
  fi

  CVM=""
}

UPDATE_VM_QEMU() {
  ui_info "Connecting via QEMU guest agent"

  if [[ "${START_WAITING:-false}" == true ]]; then
    ui_wait "Waiting ${VM_START_DELAY:-45}s for QEMU agent to start"
    sleep "${VM_START_DELAY:-45}"
  fi

  if ! qm guest exec "${VM}" test >/dev/null 2>&1; then
    ui_error "No QEMU agent or SSH found on VM ${VM}"
    echo "  SSH setup:   https://github.com/BassT23/Proxmox/blob/${BRANCH}/ssh.md"
    echo "  QEMU agent:  https://pve.proxmox.com/wiki/Qemu-guest-agent"
    CVM=""
    return 0
  fi

  ui_info "QEMU agent connected. SSH provides richer output — see: https://github.com/BassT23/Proxmox/blob/${BRANCH}/ssh.md"

  local kernel os os_family=""
  kernel=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep kernel-version || true)
  os=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep name || true)

  if [[ "${kernel}" =~ FreeBSD ]]; then
    if [[ "${FREEBSD_UPDATES:-false}" == true ]]; then
      pkg_upgrade "qemu" "${VM}"
    else
      ui_skip "FreeBSD — updates disabled"
    fi
    UPDATE_CHECK
    CVM=""
    return 0
  fi

  [[ "${os,,}" =~ ubuntu|mint|kali|debian|devuan ]] && os_family="debian"
  [[ "${os,,}" =~ fedora ]]  && os_family="fedora"
  [[ "${os,,}" =~ arch ]]    && os_family="archlinux"
  [[ "${os,,}" =~ alpine ]]  && os_family="alpine"
  [[ "${os,,}" =~ centos ]]  && os_family="centos"

  if [[ -z "${os_family}" ]]; then
    ui_error "Unsupported OS: ${os}"
    echo "  Request support: https://github.com/BassT23/Proxmox/issues"
    CVM=""
    return 0
  fi

  internet_check_on "qemu" "${VM}" || { CVM=""; return 0; }
  run_os_update "qemu" "${VM}" "${os_family}"
  UPDATE_CHECK
  CVM=""
}


# ==============================================================================
# Main
# ==============================================================================

READ_CONFIG

DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' "${CONFIG_FILE}")
[[ "${DEBUG}" == true ]] && set -x

OUTPUT_TO_FILE() {
  echo "EXEC_HOST=\"${HOSTNAME}\"" > /etc/ultimate-updater/temp/exec_host
  if [[ "${RICM:-false}" != true ]]; then
    touch "${LOG_FILE}"
    exec &> >(tee "${LOG_FILE}")
  fi
  if [[ -f /etc/update-motd.d/01-welcome-screen && -x /etc/update-motd.d/01-welcome-screen ]]; then
    WELCOME_SCREEN=true
    [[ "${RICM:-false}" != true ]] && touch "${LOCAL_FILES}/check-output"
  fi
}

if [[ "${EXIT_ON_ERROR:-false}" == false ]]; then
  ERROR_LOGGING
else
  set -e
fi

trap EXIT EXIT

if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' /etc/corosync/corosync.conf)
  MODE="Cluster"
else
  MODE="  Host "
fi

export TERM=xterm-256color
mkdir -p /etc/ultimate-updater/temp
OUTPUT_TO_FILE
IP=$(hostname -i | cut -d' ' -f1)

ARGUMENTS "$@"

if [[ "${COMMAND:-false}" != true ]]; then
  TAG_LOG=true
  HEADER_INFO
  [[ "${EXIT_ON_ERROR:-false}" == false ]] && ui_info "Continue-on-error enabled"

  if [[ "${MODE}" =~ Cluster ]]; then
    HOST_UPDATE_START
  else
    ui_update "Updating host: ${IP} (${HOSTNAME})"
    [[ "${WITH_HOST:-true}" == true ]] && UPDATE_HOST_ITSELF      || ui_skip "Host update disabled"
    [[ "${WITH_LXC:-true}"  == true ]] && CONTAINER_UPDATE_START  || ui_skip "Container updates disabled"
    [[ "${WITH_VM:-true}"   == true ]] && VM_UPDATE_START         || ui_skip "VM updates disabled"
  fi
fi

exit 0
