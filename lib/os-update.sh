#!/bin/bash

##################
# OS Update Lib  #
##################

# exec_on <method> <target> <cmd>
# Runs a command on a target using the given connection method.
#   method: host | lxc | ssh | qemu
#   target: container/VM ID (unused for host)
#   cmd:    shell command string
exec_on() {
  local method="$1" target="$2"
  shift 2
  case "${method}" in
    host) bash -c "$*" ;;
    lxc)  pct exec "${target}" -- bash -c "$*" ;;
    ssh)  ssh -q -p "${SSH_VM_PORT:-22}" -tt "${SSH_USER:-root}@${IP}" "$*" ;;
    qemu)
      local json exit_code
      json=$(qm guest exec "${target}" -- bash -c "$*" 2>/dev/null)
      exit_code=$?
      echo "${json}" | tail -n +4 | head -n -1 | cut -c 17-
      return ${exit_code}
      ;;
  esac
}

# internet_check_on <method> <target>
# Returns 1 and prints a warning if the target has no internet.
internet_check_on() {
  local method="$1" target="$2"
  local exe="${CHECK_URL_EXE:-ping}"
  local url="${CHECK_URL:-google.com}"
  local ok=true

  case "${method}" in
    lxc)
      pct exec "${target}" -- bash -c "${exe} -q -c1 ${url} &>/dev/null" || ok=false
      ;;
    ssh)
      ssh -q -p "${SSH_VM_PORT:-22}" "${SSH_USER:-root}@${IP}" "${exe} -c1 ${url}" &>/dev/null || ok=false
      ;;
    qemu)
      qm guest exec "${target}" -- bash -c "${exe} -q -c1 ${url} &>/dev/null" >/dev/null 2>&1 || ok=false
      ;;
  esac

  if [[ "${ok}" == false ]]; then
    ui_warn "No internet — skipping ${target}"
    return 1
  fi
}

# apt_upgrade <method> <target>
apt_upgrade() {
  local method="$1" target="$2"
  local unifi_detected=false
  local upgrade_cmd

  # Detect Unifi repo in LXC (needs --allow-releaseinfo-change)
  if [[ "${method}" == lxc ]]; then
    pct exec "${target}" -- bash -c "grep -rnw /etc/apt -e unifi >/dev/null 2>&1" && unifi_detected=true
  fi

  ui_section "APT UPDATE"
  if [[ "${unifi_detected}" == true ]]; then
    exec_on "${method}" "${target}" "apt-get update --allow-releaseinfo-change" || {
      log_error "${target}" "${_TARGET_NAME}" $? "apt-get update (unifi) failed"
      return 1
    }
  else
    exec_on "${method}" "${target}" "apt-get update" || {
      log_error "${target}" "${_TARGET_NAME}" $? "apt-get update failed"
      return 1
    }
  fi

  ui_section "APT UPGRADE"
  if [[ "${HEADLESS:-false}" == true || "${unifi_detected}" == true ]]; then
    upgrade_cmd="DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y"
    if [[ "${unifi_detected}" == true ]]; then
      upgrade_cmd+=" -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
    fi
  elif [[ "${INCLUDE_PHASED_UPDATES:-false}" == true ]]; then
    upgrade_cmd="apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y"
  else
    upgrade_cmd="apt-get dist-upgrade -y"
  fi

  exec_on "${method}" "${target}" "${upgrade_cmd}" || {
    log_error "${target}" "${_TARGET_NAME}" $? "apt-get upgrade failed"
    return 1
  }

  ui_section "APT CLEANUP"
  exec_on "${method}" "${target}" "apt-get --purge autoremove -y && apt-get autoclean -y" || {
    log_error "${target}" "${_TARGET_NAME}" $? "apt-get cleanup failed"
    return 1
  }

  _check_reboot "${method}" "${target}"
}

# dnf_upgrade <method> <target>
dnf_upgrade() {
  local method="$1" target="$2"

  ui_section "DNF UPGRADE"
  exec_on "${method}" "${target}" "dnf -y upgrade" || {
    log_error "${target}" "${_TARGET_NAME}" $? "dnf upgrade failed"
    return 1
  }

  ui_section "DNF CLEANUP"
  exec_on "${method}" "${target}" "dnf -y autoremove" || {
    log_error "${target}" "${_TARGET_NAME}" $? "dnf autoremove failed"
    return 1
  }
}

# pacman_upgrade <method> <target>
pacman_upgrade() {
  local method="$1" target="$2"

  ui_section "PACMAN UPDATE"
  exec_on "${method}" "${target}" "${PACMAN_ENVIRONMENT:-} pacman -Su --noconfirm" || {
    log_error "${target}" "${_TARGET_NAME}" $? "pacman upgrade failed"
    return 1
  }
}

# apk_upgrade <method> <target>
apk_upgrade() {
  local method="$1" target="$2"

  ui_section "APK UPDATE"
  if [[ "${method}" == lxc ]]; then
    pct exec "${target}" -- ash -c "apk -U upgrade" || {
      log_error "${target}" "${_TARGET_NAME}" $? "apk upgrade failed"
      return 1
    }
  else
    exec_on "${method}" "${target}" "apk -U upgrade" || {
      log_error "${target}" "${_TARGET_NAME}" $? "apk upgrade failed"
      return 1
    }
  fi
}

# yum_upgrade <method> <target>
yum_upgrade() {
  local method="$1" target="$2"

  ui_section "YUM UPDATE"
  exec_on "${method}" "${target}" "yum -y update" || {
    log_error "${target}" "${_TARGET_NAME}" $? "yum update failed"
    return 1
  }
}

# pkg_upgrade <method> <target>  (FreeBSD)
pkg_upgrade() {
  local method="$1" target="$2"

  ui_section "PKG UPDATE"
  exec_on "${method}" "${target}" "pkg update" || {
    log_error "${target}" "${_TARGET_NAME}" $? "pkg update failed"
    return 1
  }

  ui_section "PKG UPGRADE"
  exec_on "${method}" "${target}" "pkg upgrade -y" || {
    log_error "${target}" "${_TARGET_NAME}" $? "pkg upgrade failed"
    return 1
  }

  ui_section "PKG CLEANUP"
  exec_on "${method}" "${target}" "pkg autoremove -y" || {
    log_error "${target}" "${_TARGET_NAME}" $? "pkg autoremove failed"
    return 1
  }
}

# run_os_update <method> <target> <os>
# Detects OS family and runs the appropriate package manager.
run_os_update() {
  local method="$1" target="$2" os="${3,,}"

  case "${os}" in
    ubuntu|debian|devuan) apt_upgrade   "${method}" "${target}" ;;
    fedora)               dnf_upgrade   "${method}" "${target}" ;;
    archlinux)            pacman_upgrade "${method}" "${target}" ;;
    alpine)               apk_upgrade   "${method}" "${target}" ;;
    centos)               yum_upgrade   "${method}" "${target}" ;;
    freebsd)
      if [[ "${FREEBSD_UPDATES:-false}" == true ]]; then
        pkg_upgrade "${method}" "${target}"
      else
        ui_skip "FreeBSD updates disabled"
      fi
      ;;
    *)
      ui_warn "Unknown OS '${os}' — cannot update"
      ;;
  esac
}

# _check_reboot <method> <target>
# Reboots the target if REEBOOT_IF_NEEDED=true and reboot is required.
_check_reboot() {
  local method="$1" target="$2"
  [[ "${REEBOOT_IF_NEEDED:-false}" != true ]] && return 0

  local needs_reboot=false
  case "${method}" in
    lxc)
      pct exec "${target}" -- bash -c "[ -f /var/run/reboot-required ]" &>/dev/null && needs_reboot=true
      ;;
    ssh)
      ssh -q -p "${SSH_VM_PORT:-22}" "${SSH_USER:-root}@${IP}" "[ -f /var/run/reboot-required ]" &>/dev/null && needs_reboot=true
      ;;
    qemu)
      [[ $(qm guest exec "${target}" -- bash -c "[ -f /var/run/reboot-required ]" 2>/dev/null | grep exitcode) =~ 0 ]] && needs_reboot=true
      ;;
  esac

  if [[ "${needs_reboot}" == true ]]; then
    ui_info "Reboot required — rebooting ${target}"
    exec_on "${method}" "${target}" "reboot" &>/dev/null || true
  fi
}
