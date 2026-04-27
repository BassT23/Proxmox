#!/bin/bash

#################
# Check Updates #
#################
# Checks each host, container, and VM for pending package updates.
# Results are written to check-output and optionally emailed.
# This script is called by the welcome screen cron job.

VERSION="2.0.0"

LOCAL_FILES="/etc/ultimate-updater"
CONFIG_FILE="${LOCAL_FILES}/update.conf"

# shellcheck source=tag-filter.sh
source "${LOCAL_FILES}/tag-filter.sh"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

ARGUMENTS() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c) RICM=true ;;
      -u) RDU=true ;;
      chost)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_HOST_ITSELF
        ;;
      ccontainer)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_CONTAINER
        ;;
      cvm)
        COMMAND=true
        OUTPUT_TO_FILE
        CHECK_VM
        ;;
      host)
        COMMAND=true
        OUTPUT_TO_FILE
        [[ "${WITH_HOST:-true}"  == true ]] && CHECK_HOST_ITSELF
        [[ "${WITH_LXC:-true}"   == true ]] && CONTAINER_CHECK_START
        [[ "${WITH_VM:-true}"    == true ]] && VM_CHECK_START
        ;;
      cluster)
        COMMAND=true
        OUTPUT_TO_FILE
        HOST_CHECK_START
        ;;
      *)
        echo -e "${RD}Unknown argument: $1${CL}" >&2
        USAGE
        exit 2
        ;;
    esac
    shift
  done
}

USAGE() {
  cat <<EOF

Usage: check-updates.sh [COMMAND]

Commands:
  host     Check this host, all containers, and all VMs
  cluster  Check all cluster nodes

EOF
}

READ_CONFIG() {
  _cfg() { awk -F'"' "/^${1}=/ {print \$2}" "${CONFIG_FILE}"; }

  SSH_PORT=$(_cfg SSH_PORT)
  EMAIL_USER=$(_cfg EMAIL_USER)
  EMAIL_NO_UPDATES=$(_cfg EMAIL_NO_UPDATES)
  EMAIL_ONLY_SECURITY=$(_cfg EMAIL_ONLY_SECURITY)
  WITH_HOST=$(_cfg CHECK_WITH_HOST)
  WITH_LXC=$(_cfg CHECK_WITH_LXC)
  WITH_VM=$(_cfg CHECK_WITH_VM)
  RUNNING=$(_cfg CHECK_RUNNING_CONTAINER)
  STOPPED=$(_cfg CHECK_STOPPED_CONTAINER)
  RUNNING_VM=$(_cfg CHECK_RUNNING_VM)
  STOPPED_VM=$(_cfg CHECK_STOPPED_VM)
  PAUSED_VM=$(_cfg CHECK_PAUSED_VM)
  REEBOOT_IF_NEEDED=$(_cfg REEBOOT_IF_NEEDED)
  LXC_START_DELAY=$(_cfg LXC_START_DELAY)
  EXCLUDED=$(_cfg EXCLUDE_UPDATE_CHECK)
  ONLY=$(_cfg ONLY_UPDATE_CHECK)
  CHECK_URL=$(_cfg URL_FOR_INTERNET_CHECK)

  declare -f apply_only_exclude_tags >/dev/null 2>&1 && \
    apply_only_exclude_tags ONLY EXCLUDED
}

WAIT_FOR_BOOTUP_LXC() {
  local count=1 max=10
  sleep "${LXC_START_DELAY:-5}"
  while [[ ${count} -le ${max} ]]; do
    pct exec "${CONTAINER}" -- bash -c "exit" >/dev/null 2>&1 && return 0
    sleep "${LXC_START_DELAY:-5}"
    (( count++ ))
  done
}

# ==============================================================================
# Host
# ==============================================================================

HOST_CHECK_START() {
  for host in ${HOSTS}; do
    CHECK_HOST "${host}"
  done
}

CHECK_HOST() {
  local host="$1"
  ssh "${host}" -p "${SSH_PORT:-22}" mkdir -p "${LOCAL_FILES}"
  scp "${CONFIG_FILE}" "${host}:${CONFIG_FILE}" >/dev/null 2>&1
  ssh "${host}" -p "${SSH_PORT:-22}" 'bash -s' < "$0" -- "-c host"
}

CHECK_HOST_ITSELF() {
  apt-get update >/dev/null 2>&1
  local security_updates normal_updates
  security_updates=$(apt-get -s upgrade 2>/dev/null | grep -ci "^inst.*security" | tr -d '\n')
  normal_updates=$(apt-get -s upgrade 2>/dev/null | grep -ci "^inst." | tr -d '\n')
  local reboot_required=false
  [[ -f /var/run/reboot-required.pkgs ]] && reboot_required=true
  [[ "${security_updates}" -gt 0 ]] && SECURITY_UPDATES_FOUND=true

  if [[ "${security_updates}" -gt 0 || "${normal_updates}" -gt 0 || "${reboot_required}" == true ]]; then
    echo -e "${BL}Host${CL} : ${GN}${HOSTNAME}${CL}"
  fi
  [[ "${reboot_required}" == true ]]    && echo -e "${OR} Reboot required${CL}"
  [[ "${security_updates}" -gt 0 && "${normal_updates}" -gt 0 ]] && echo -e "S: ${security_updates} / N: ${normal_updates}"
  [[ "${security_updates}" -gt 0 && "${normal_updates}" -eq 0 ]] && echo -e "S: ${security_updates}"
  [[ "${security_updates}" -eq 0 && "${normal_updates}" -gt 0 ]] && echo -e "N: ${normal_updates}"
}

# ==============================================================================
# Containers
# ==============================================================================

CONTAINER_CHECK_START() {
  local containers
  containers=$(pct list | tail -n +2 | cut -f1 -d' ')
  mkdir -p "${LOCAL_FILES}/temp"

  for CONTAINER in ${containers}; do
    if [[ -z "${ONLY:-}" && "${EXCLUDED:-}" =~ ${CONTAINER} ]]; then continue; fi
    if [[ -n "${ONLY:-}" ]] && ! [[ "${ONLY}" =~ ${CONTAINER} ]]; then continue; fi
    pct config "${CONTAINER}" | grep -q template && continue

    local status
    status=$(pct status "${CONTAINER}")
    if [[ "${status}" == "status: stopped" && "${STOPPED:-true}" == true ]]; then
      pct start "${CONTAINER}"
      WAIT_FOR_BOOTUP_LXC
      CHECK_CONTAINER "${CONTAINER}"
      pct shutdown "${CONTAINER}"
    elif [[ "${status}" == "status: running" && "${RUNNING:-true}" == true ]]; then
      CHECK_CONTAINER "${CONTAINER}"
    fi
  done

  rm -rf "${LOCAL_FILES}/temp/temp"
}

CHECK_CONTAINER() {
  if [[ "${RDU:-false}" != true ]]; then
    CONTAINER="$1"
  else
    CONTAINER=$(awk -F'"' '/^CONTAINER=/ {print $2}' "${LOCAL_FILES}/temp/var")
  fi

  pct config "${CONTAINER}" > "${LOCAL_FILES}/temp/temp"
  local os name
  os=$(awk '/^ostype/ {print $2}' "${LOCAL_FILES}/temp/temp")
  name=$(pct exec "${CONTAINER}" hostname 2>/dev/null || echo "${CONTAINER}")

  if [[ "${os,,}" =~ ubuntu|debian|devuan ]]; then
    pct exec "${CONTAINER}" -- bash -c "apt-get update" >/dev/null 2>&1
    local apt_output security_updates normal_updates
    apt_output=$(pct exec "${CONTAINER}" -- bash -c "apt-get -s upgrade")
    security_updates=$(echo "${apt_output}" | grep -ci '^inst.*security' || true)
    normal_updates=$(echo "${apt_output}" | grep -ci '^inst.' || true)
    [[ "${security_updates}" -gt 0 ]] && SECURITY_UPDATES_FOUND=true
    if [[ "${security_updates}" -gt 0 || "${normal_updates}" -gt 0 ]]; then
      echo -e "${GN}LXC ${BL}${CONTAINER}${CL} : ${GN}${name}${CL}"
      [[ "${security_updates}" -gt 0 && "${normal_updates}" -gt 0 ]] && echo -e "S: ${security_updates} / N: ${normal_updates}"
      [[ "${security_updates}" -gt 0 && "${normal_updates}" -eq 0 ]] && echo -e "S: ${security_updates}"
      [[ "${security_updates}" -eq 0 && "${normal_updates}" -gt 0 ]] && echo -e "N: ${normal_updates}"
    fi
  elif [[ "${os,,}" =~ fedora ]]; then
    pct exec "${CONTAINER}" -- bash -c "dnf update" >/dev/null 2>&1
    local updates
    updates=$(pct exec "${CONTAINER}" -- bash -c "dnf check-update | grep -Ec ' updates$'" || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}LXC ${BL}${CONTAINER}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  elif [[ "${os,,}" =~ archlinux ]]; then
    pct exec "${CONTAINER}" -- bash -c "pacman -Syu" >/dev/null 2>&1
    local updates
    updates=$(pct exec "${CONTAINER}" -- bash -c "pacman -Qu | wc -l" || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}LXC ${BL}${CONTAINER}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  else
    pct exec "${CONTAINER}" -- bash -c "yum update" >/dev/null 2>&1
    local updates
    updates=$(pct exec "${CONTAINER}" -- bash -c "yum -q check-update | wc -l" || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}LXC ${BL}${CONTAINER}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  fi
}

# ==============================================================================
# VMs
# ==============================================================================

VM_CHECK_START() {
  local vms
  vms=$(qm list | tail -n +2 | cut -c -10)

  for VM in ${vms}; do
    if [[ -z "${ONLY:-}" && "${EXCLUDED:-}" =~ ${VM} ]]; then continue; fi
    if [[ -n "${ONLY:-}" ]] && ! [[ "${ONLY}" =~ ${VM} ]]; then continue; fi

    local pre_os
    pre_os=$(qm config "${VM}" | grep 'ostype:' | sed 's/ostype:\s*//')
    [[ "${pre_os}" =~ w ]] && continue

    if [[ $(qm config "${VM}" | grep 'agent:' | sed 's/agent:\s*//') != 1 ]] \
       && [[ ! -f "${LOCAL_FILES}/VMs/${VM}" ]]; then
      continue
    fi

    local status
    status=$(qm status "${VM}")

    if [[ "${status}" == "status: stopped" && "${STOPPED_VM:-true}" == true ]]; then
      [[ $(qm config "${VM}" | grep 'lock:' | sed 's/lock:\s*//') == suspend ]] && continue
      qm start "${VM}" >/dev/null 2>&1
      local delay="${SSH_START_DELAY_TIME:-45}"
      sleep "${delay}"
      sleep "${delay}"
      CHECK_VM "${VM}"
      qm shutdown "${VM}" --timeout 30 >/dev/null 2>&1 || qm stop "${VM}" >/dev/null 2>&1
    elif [[ "${status}" == "status: paused" && "${PAUSED_VM:-true}" == true ]]; then
      qm resume "${VM}" >/dev/null 2>&1
      sleep "${SSH_START_DELAY_TIME:-45}"
      CHECK_VM "${VM}"
      qm suspend "${VM}"
    elif [[ "${status}" == "status: running" && "${RUNNING_VM:-true}" == true ]]; then
      VM_NOT_STOPPED=true
      CHECK_VM "${VM}"
      VM_NOT_STOPPED=""
    fi
  done
}

CHECK_VM() {
  if [[ "${RDU:-false}" != true ]]; then
    VM="$1"
  else
    VM=$(awk -F'"' '/^VM=/ {print $2}' "${LOCAL_FILES}/temp/var")
  fi

  local name
  name=$(qm config "${VM}" | grep 'name:' | sed 's/name:\s*//')

  if [[ -f "${LOCAL_FILES}/VMs/${VM}" ]]; then
    local ip user ssh_port
    ip=$(awk -F'"' '/^IP=/ {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    user=$(awk -F'"' '/^USER=/ {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    ssh_port=$(awk -F'"' '/^SSH_VM_PORT=/ {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    user="${user:-root}"
    ssh_port="${ssh_port:-22}"
    SSH_START_DELAY_TIME=$(awk -F'"' '/^SSH_START_DELAY_TIME=/ {print $2}' "${LOCAL_FILES}/VMs/${VM}")
    SSH_START_DELAY_TIME="${SSH_START_DELAY_TIME:-45}"

    if ! ssh "${ip}" exit >/dev/null 2>&1; then
      CHECK_VM_QEMU
      return
    fi

    local os_base kernel os
    os_base=$(qm config "${VM}" | grep ostype || true)
    [[ "${os_base}" =~ l2 ]] || { CHECK_VM_QEMU; return; }

    kernel=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep kernel-version || true)
    os=$(ssh -q -p "${ssh_port}" "${user}@${ip}" hostnamectl 2>/dev/null | grep System || true)

    if [[ "${os,,}" =~ ubuntu|mint|kali|debian|devuan ]]; then
      ssh -q -p "${ssh_port}" "${user}@${ip}" "apt-get update" >/dev/null 2>&1
      local apt_output security_updates normal_updates reboot_required=false
      apt_output=$(ssh -q -p "${ssh_port}" "${user}@${ip}" "apt-get -s upgrade")
      security_updates=$(echo "${apt_output}" | grep -ci '^inst.*security' || true)
      normal_updates=$(echo "${apt_output}" | grep -ci '^inst.' || true)
      ssh -q -p "${ssh_port}" "${user}@${ip}" \
        "stat /var/run/reboot-required.pkgs" >/dev/null 2>&1 && reboot_required=true
      [[ "${security_updates}" -gt 0 ]] && SECURITY_UPDATES_FOUND=true
      if [[ "${security_updates}" -gt 0 || "${normal_updates}" -gt 0 || "${reboot_required}" == true ]]; then
        echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}"
      fi
      [[ "${reboot_required}" == true ]] && echo -e "${OR} Reboot required${CL}"
      [[ "${security_updates}" -gt 0 && "${normal_updates}" -gt 0 ]] && echo -e "S: ${security_updates} / N: ${normal_updates}"
      [[ "${security_updates}" -gt 0 && "${normal_updates}" -eq 0 ]] && echo -e "S: ${security_updates}"
      [[ "${security_updates}" -eq 0 && "${normal_updates}" -gt 0 ]] && echo -e "N: ${normal_updates}"
      if [[ "${reboot_required}" == true && "${REEBOOT_IF_NEEDED:-false}" == true \
            && "${VM_NOT_STOPPED:-false}" == true ]]; then
        ssh -q -p "${ssh_port}" "${user}@${ip}" "reboot" >/dev/null 2>&1
      fi
    elif [[ "${os}" =~ Fedora ]]; then
      local updates
      updates=$(ssh -q -p "${ssh_port}" "${user}@${ip}" "dnf check-update | grep -Ec ' updates$'" || true)
      [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
    elif [[ "${os}" =~ Arch ]]; then
      local updates
      updates=$(ssh -q -p "${ssh_port}" "${user}@${ip}" "pacman -Qu | wc -l" || true)
      [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
    elif [[ "${os}" =~ CentOS ]]; then
      local updates
      updates=$(ssh -q -p "${ssh_port}" "${user}@${ip}" "yum -q check-update | wc -l" || true)
      [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
    fi
  else
    CHECK_VM_QEMU
  fi
}

CHECK_VM_QEMU() {
  qm guest exec "${VM}" test >/dev/null 2>&1 || return 0

  local kernel os
  kernel=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep kernel-version || true)
  os=$(qm guest cmd "${VM}" get-osinfo 2>/dev/null | grep name || true)
  local name
  name=$(qm config "${VM}" | grep 'name:' | sed 's/name:\s*//')

  if [[ "${os,,}" =~ ubuntu|mint|kali|debian|devuan ]]; then
    qm guest exec "${VM}" -- bash -c "apt-get update" >/dev/null 2>&1
    local security_updates normal_updates reboot_required=false
    security_updates=$(qm guest exec "${VM}" -- bash -c \
      "apt-get -s upgrade | grep -ci ^inst.*security | tr -d '\n'" \
      | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
    normal_updates=$(qm guest exec "${VM}" -- bash -c \
      "apt-get -s upgrade | grep -ci ^inst. | tr -d '\n'" \
      | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev)
    [[ $(qm guest exec "${VM}" -- bash -c \
      "[ -f /var/run/reboot-required.pkgs ]" 2>/dev/null | grep exitcode) =~ 0 ]] \
      && reboot_required=true
    [[ "${security_updates:-0}" -gt 0 ]] && SECURITY_UPDATES_FOUND=true
    if [[ "${security_updates:-0}" -gt 0 || "${normal_updates:-0}" -gt 0 || "${reboot_required}" == true ]]; then
      echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}"
    fi
    [[ "${reboot_required}" == true ]] && echo -e "${OR} Reboot required${CL}"
    [[ "${security_updates:-0}" -gt 0 && "${normal_updates:-0}" -gt 0 ]] && echo -e "S: ${security_updates} / N: ${normal_updates}"
    [[ "${security_updates:-0}" -gt 0 && "${normal_updates:-0}" -eq 0 ]] && echo -e "S: ${security_updates}"
    [[ "${security_updates:-0}" -eq 0 && "${normal_updates:-0}" -gt 0 ]] && echo -e "N: ${normal_updates}"
  elif [[ "${os}" =~ Fedora ]]; then
    local updates
    updates=$(qm guest exec "${VM}" -- bash -c "dnf check-update | grep -Ec ' updates$'" \
      | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  elif [[ "${os}" =~ Arch ]]; then
    local updates
    updates=$(qm guest exec "${VM}" -- bash -c "pacman -Qu | wc -l" \
      | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  elif [[ "${os}" =~ CentOS ]]; then
    local updates
    updates=$(qm guest exec "${VM}" -- bash -c "yum -q check-update | wc -l" \
      | tail -n +4 | head -n -1 | cut -c 18- | rev | cut -c 2- | rev || true)
    [[ "${updates:-0}" -gt 0 ]] && echo -e "${GN}VM ${BL}${VM}${CL} : ${GN}${name}${CL}" && echo "${updates}"
  fi
}

# ==============================================================================
# Output / email
# ==============================================================================

OUTPUT_TO_FILE() {
  if [[ "${RDU:-false}" != true && "${RICM:-false}" != true ]]; then
    touch "${LOCAL_FILES}/check-output"
    exec > >(tee "${LOCAL_FILES}/check-output")
    touch "${LOCAL_FILES}/mail-output"
    {
      echo "Available updates:"
      echo "S = Security / N = Normal"
      echo ""
    } > "${LOCAL_FILES}/mail-output"
    exec > >(tee -a "${LOCAL_FILES}/mail-output")
  fi
}

EXIT() {
  if [[ "${RDU:-false}" == true || "${RICM:-false}" == true ]]; then return; fi
  if [[ ! -f "${LOCAL_FILES}/mail-output" ]]; then return; fi

  # Strip ANSI colour codes from mail output
  sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" \
    "${LOCAL_FILES}/mail-output" > "${LOCAL_FILES}/mail-output.tmp" \
    && mv "${LOCAL_FILES}/mail-output.tmp" "${LOCAL_FILES}/mail-output"
  chmod 640 "${LOCAL_FILES}/mail-output"

  # Send email if updates were found
  local mail_size
  mail_size=$(stat -c%s "${LOCAL_FILES}/mail-output")
  if [[ "${mail_size}" -gt 46 ]]; then
    if [[ "${EMAIL_ONLY_SECURITY:-false}" == true && "${SECURITY_UPDATES_FOUND:-false}" != true ]]; then
      : # security-only mode and no security updates — skip
    else
      mail -s "Ultimate Updater — ${HOSTNAME}" "${EMAIL_USER:-root}" \
        < "${LOCAL_FILES}/mail-output" 2>/dev/null || true
    fi
  elif [[ "${EMAIL_NO_UPDATES:-false}" == true ]]; then
    echo "No updates found." \
      | mail -s "Ultimate Updater — ${HOSTNAME}" "${EMAIL_USER:-root}" 2>/dev/null || true
  fi
}
trap EXIT EXIT

# ==============================================================================
# Main
# ==============================================================================

DEBUG=$(awk -F'"' '/^DEBUG=/ {print $2}' "${CONFIG_FILE}")
[[ "${DEBUG}" == true ]] && set -x

if [[ -f /etc/corosync/corosync.conf ]]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' /etc/corosync/corosync.conf)
  MODE="Cluster"
else
  MODE="Host"
fi

READ_CONFIG

if wget -q --spider "${CHECK_URL:-google.com}" >/dev/null 2>&1; then
  ARGUMENTS "$@"
  if [[ "${RDU:-false}" != true && "${RICM:-false}" != true ]]; then
    declare -f print_tag_log >/dev/null 2>&1 && print_tag_log || true
  fi
else
  echo -e "${OR}No internet connection${CL}"
  exit 2
fi

if [[ "${COMMAND:-false}" != true ]]; then
  OUTPUT_TO_FILE
  if [[ "${MODE}" =~ Cluster ]]; then
    HOST_CHECK_START
  else
    [[ "${WITH_HOST:-true}" == true ]] && CHECK_HOST_ITSELF
    [[ "${WITH_LXC:-true}"  == true ]] && CONTAINER_CHECK_START
    [[ "${WITH_VM:-true}"   == true ]] && VM_CHECK_START
  fi
fi

exit 0
