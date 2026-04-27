#!/bin/bash

###########
# Install #
###########

VERSION="2.0.0"

BRANCH="master"

LOCAL_FILES="/etc/ultimate-updater"
TEMP_FOLDER="/root/Ultimate-Updater-Temp"
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/${BRANCH}"

# Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

HEADER_INFO() {
  clear
  echo -e "\n      https://github.com/BassT23/Proxmox\n"
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
      /_/     for Proxmox VE
EOF
  echo -e "\n      Installer version: ${VERSION}\n"
  CHECK_ROOT
}

CHECK_ROOT() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RD}  Please run this as root.${CL}" >&2
    exit 1
  fi
}

ARGUMENTS() {
  while test $# -gt 0; do
    case "$1" in
      -h|--help) USAGE; exit 0 ;;
      status)    STATUS ;;
      install)   COMMAND=true; INSTALL;        WELCOME_SCREEN; EXIT ;;
      update)    COMMAND=true; UPDATE;                         EXIT ;;
      uninstall) COMMAND=true; UNINSTALL;                      EXIT ;;
      welcome)               WELCOME_SCREEN;                   EXIT ;;
      *)
        echo -e "${RD}Unknown argument: $1${CL}" >&2
        USAGE
        exit 1
        ;;
    esac
    shift
  done
}

USAGE() {
  cat <<EOF

Usage: bash install.sh [COMMAND]

Commands:
  install     Install The Ultimate Updater
  update      Update an existing installation
  uninstall   Remove The Ultimate Updater
  welcome     Install or remove the welcome screen
  status      Check installation status
  -h, --help  Show this help message

EOF
}

IS_INSTALLED() {
  [[ -f /usr/local/sbin/update ]]
}

STATUS() {
  echo "The Ultimate Updater"
  if IS_INSTALLED; then
    echo -e "Status: ${GN}installed${CL}"
    exit 0
  else
    echo -e "Status: ${RD}not installed${CL}"
    exit 1
  fi
}

OLD_FILESYSTEM_CHECK() {
  # Migrate from legacy directory names
  if [[ -d /root/Proxmox-Updater/ ]]; then
    mv /root/Proxmox-Updater/ "${LOCAL_FILES}/"
  fi
  # Migrate symlink from /usr/local/bin to /usr/local/sbin
  if [[ -f /usr/local/bin/update && ! -f /usr/local/sbin/update ]]; then
    curl -sf "https://raw.githubusercontent.com/BassT23/Proxmox/${BRANCH}/update.sh" \
      > "${LOCAL_FILES}/update.sh"
    chmod 750 "${LOCAL_FILES}/update.sh"
    ln -sf "${LOCAL_FILES}/update.sh" /usr/local/sbin/update
    rm /usr/local/bin/update
    NEED_REBOOT=true
  fi
}

_download() {
  if ! [[ -d "${TEMP_FOLDER}" ]]; then mkdir "${TEMP_FOLDER}"; fi
  if [[ "${BRANCH}" == master ]]; then
    curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest \
      | grep "browser_download_url" | cut -d: -f2,3 | tr -d \" \
      | wget -i - -q -O "${TEMP_FOLDER}/ultimate-updater.tar.gz"
  else
    curl -sL "https://github.com/BassT23/Proxmox/tarball/${BRANCH}" \
      > "${TEMP_FOLDER}/ultimate-updater.tar.gz"
  fi
  tar -zxf "${TEMP_FOLDER}/ultimate-updater.tar.gz" -C "${TEMP_FOLDER}"
  rm -f "${TEMP_FOLDER}/ultimate-updater.tar.gz"
  if [[ "${BRANCH}" == master ]]; then
    TEMP_FILES="${TEMP_FOLDER}"
  else
    TEMP_FILES="${TEMP_FOLDER}/$(ls "${TEMP_FOLDER}")"
  fi
}

_copy_files() {
  local src="$1"

  # Core files
  cp "${src}/update.sh"        "${LOCAL_FILES}/update.sh"
  cp "${src}/run-plugins.sh"   "${LOCAL_FILES}/run-plugins.sh"
  cp "${src}/tag-filter.sh"    "${LOCAL_FILES}/tag-filter.sh"
  cp "${src}/check-updates.sh" "${LOCAL_FILES}/check-updates.sh"

  # Libraries
  mkdir -p "${LOCAL_FILES}/lib"
  cp "${src}/lib/"*.sh "${LOCAL_FILES}/lib/"

  # Plugins
  mkdir -p "${LOCAL_FILES}/plugins"
  cp "${src}/plugins/"*.sh "${LOCAL_FILES}/plugins/"

  # Support files
  cp "${src}/exit/"* "${LOCAL_FILES}/exit/"

  # VM SSH config examples
  [[ -f "${src}/VMs/example" ]] && cp "${src}/VMs/example" "${LOCAL_FILES}/VMs/example"

  # User scripts example
  if [[ -d "${src}/scripts.d/000" ]]; then
    cp "${src}/scripts.d/000/"* "${LOCAL_FILES}/scripts.d/000/" 2>/dev/null || true
  fi

  chmod 750 "${LOCAL_FILES}/update.sh"
  chmod +x "${LOCAL_FILES}/run-plugins.sh"
  chmod +x "${LOCAL_FILES}/check-updates.sh"
  chmod -R +x "${LOCAL_FILES}/lib/"
  chmod -R +x "${LOCAL_FILES}/plugins/"
  chmod -R +x "${LOCAL_FILES}/exit/"
}

INSTALL() {
  echo -e "\n${GN}Installing The Ultimate Updater${CL}\n"

  if IS_INSTALLED; then
    echo -e "${OR}Already installed.${CL}"
    read -rp "Update instead? [Y/y/Enter = yes]: " _reply
    if [[ "${_reply}" =~ ^[Yy]$ || "${_reply}" == "" ]]; then
      bash <(curl -s "${SERVER_URL}/install.sh") update
    fi
    return
  fi

  mkdir -p "${LOCAL_FILES}/exit"
  mkdir -p "${LOCAL_FILES}/VMs"
  mkdir -p "${LOCAL_FILES}/scripts.d/000"
  mkdir -p "${LOCAL_FILES}/lib"
  mkdir -p "${LOCAL_FILES}/plugins"
  mkdir -p "${LOCAL_FILES}/temp"

  _download
  _copy_files "${TEMP_FILES}"

  # Config — only copy if not already present
  if [[ ! -f "${LOCAL_FILES}/update.conf" ]]; then
    cp "${TEMP_FILES}/update.conf" "${LOCAL_FILES}/update.conf"
  fi

  ln -sf "${LOCAL_FILES}/update.sh" /usr/local/sbin/update

  echo -e "${GN}Installed. Run The Ultimate Updater with: update${CL}"
  echo "Documentation: https://github.com/BassT23/Proxmox"
  echo ""

  read -rp "Also install the welcome screen? [Y/y/Enter = yes]: " _reply
  if [[ "${_reply}" =~ ^[Yy]$ || "${_reply}" == "" ]]; then
    WELCOME_SCREEN_INSTALL
  fi

  rm -rf "${TEMP_FOLDER}"
}

UPDATE() {
  OLD_FILESYSTEM_CHECK

  if ! IS_INSTALLED; then
    echo -e "${OR}Not installed. Run: bash install.sh install${CL}"
    exit 1
  fi

  echo -e "\n${GN}Updating The Ultimate Updater${CL}\n"
  rm -rf "${TEMP_FOLDER}"
  _download

  # Copy new files
  cp "${TEMP_FILES}/update.sh"        "${LOCAL_FILES}/update.sh"
  cp "${TEMP_FILES}/run-plugins.sh"   "${LOCAL_FILES}/run-plugins.sh"
  cp "${TEMP_FILES}/tag-filter.sh"    "${LOCAL_FILES}/tag-filter.sh"
  cp "${TEMP_FILES}/check-updates.sh" "${LOCAL_FILES}/check-updates.sh"

  # Libraries (always replace)
  mkdir -p "${LOCAL_FILES}/lib"
  cp "${TEMP_FILES}/lib/"*.sh "${LOCAL_FILES}/lib/"

  # Plugins (always replace shipped plugins; user plugins are left alone
  # because we only copy files that exist in the downloaded archive)
  mkdir -p "${LOCAL_FILES}/plugins"
  cp "${TEMP_FILES}/plugins/"*.sh "${LOCAL_FILES}/plugins/"

  cp "${TEMP_FILES}/exit/"*       "${LOCAL_FILES}/exit/"
  [[ -f "${TEMP_FILES}/VMs/example" ]] && cp "${TEMP_FILES}/VMs/example" "${LOCAL_FILES}/VMs/example"

  chmod 750 "${LOCAL_FILES}/update.sh"
  chmod +x "${LOCAL_FILES}/run-plugins.sh" "${LOCAL_FILES}/check-updates.sh"
  chmod -R +x "${LOCAL_FILES}/lib/" "${LOCAL_FILES}/plugins/" "${LOCAL_FILES}/exit/"

  # Config — prompt if different from installed
  if [[ -f "${TEMP_FILES}/update.conf" ]]; then
    if ! cmp -s "${TEMP_FILES}/update.conf" "${LOCAL_FILES}/update.conf"; then
      echo ""
      echo "The configuration file has changed in this release."
      echo "Options:"
      echo "  Y — install new version (your current file is backed up as update.conf.bak)"
      echo "  N — keep your current file"
      echo "  S — show differences"
      read -rp "update.conf [Y/y/N/n/S/s, default=N]: " _reply
      case "${_reply,,}" in
        y|"")
          cp -f "${LOCAL_FILES}/update.conf" "${LOCAL_FILES}/update.conf.bak"
          cp "${TEMP_FILES}/update.conf" "${LOCAL_FILES}/update.conf"
          echo "New config installed (old saved as update.conf.bak)"
          ;;
        s)
          diff "${TEMP_FILES}/update.conf" "${LOCAL_FILES}/update.conf" || true
          read -rp "Install new version? [Y/y = yes, anything else = keep]: " _reply2
          if [[ "${_reply2,,}" =~ ^y$ ]]; then
            cp -f "${LOCAL_FILES}/update.conf" "${LOCAL_FILES}/update.conf.bak"
            cp "${TEMP_FILES}/update.conf" "${LOCAL_FILES}/update.conf"
            echo "New config installed (old saved as update.conf.bak)"
          fi
          ;;
        *)
          echo "Keeping current config."
          ;;
      esac
    fi
  fi

  # Welcome screen
  if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
    cp "${TEMP_FILES}/welcome-screen.sh" /etc/update-motd.d/01-welcome-screen
    chmod +x /etc/update-motd.d/01-welcome-screen
    # Migrate old crontab entry
    if grep -q "/etc/ultimate-updater/check-updates.sh" /etc/crontab 2>/dev/null; then
      cp /etc/crontab "/etc/crontab.bak.$(date +%Y%m%d-%H%M%S)"
      sed -i 's|/etc/ultimate-updater/check-updates.sh|update -check >/dev/null 2>\&1|' /etc/crontab
    fi
  fi

  rm -rf "${TEMP_FOLDER}"

  echo -e "${GN}Update complete.${CL}"
  [[ "${BRANCH}" != master ]] && echo -e "${OR}Branch: ${BRANCH}${CL}"
  [[ "${NEED_REBOOT:-false}" == true ]] && echo -e "${RD}Please reboot this node.${CL}"
  echo ""
}

WELCOME_SCREEN() {
  if [[ "${COMMAND:-false}" == true ]]; then return; fi

  if [[ ! -f /etc/update-motd.d/01-welcome-screen ]]; then
    echo -e "\n${OR}Welcome screen is not installed.${CL}"
    read -rp "Install it? [Y/y/Enter = yes]: " _reply
    if [[ "${_reply}" =~ ^[Yy]$ || "${_reply}" == "" ]]; then
      if ! [[ -d "${TEMP_FOLDER}" ]]; then mkdir "${TEMP_FOLDER}"; fi
      curl -sf "${SERVER_URL}/welcome-screen.sh" > "${TEMP_FOLDER}/welcome-screen.sh"
      WELCOME_SCREEN_INSTALL
    fi
  else
    echo -e "\n${OR}Welcome screen is already installed.${CL}"
    read -rp "Uninstall it? [Y/y = yes]: " _reply
    if [[ "${_reply}" =~ ^[Yy]$ ]]; then
      rm -f /etc/update-motd.d/01-welcome-screen /etc/motd
      [[ -f /etc/motd.bak ]] && mv /etc/motd.bak /etc/motd
      sed -i '\|update -check >/dev/null 2>&1|d' /etc/crontab
      echo "Welcome screen removed."
    fi
  fi
  rm -rf "${TEMP_FOLDER}"
}

WELCOME_SCREEN_INSTALL() {
  [[ -f /etc/motd ]] && mv /etc/motd /etc/motd.bak
  touch /etc/motd
  cp /etc/crontab /etc/crontab.bak
  cp "${TEMP_FOLDER}/welcome-screen.sh" /etc/update-motd.d/01-welcome-screen
  chmod +x /etc/update-motd.d/01-welcome-screen
  [[ ! -f "${LOCAL_FILES}/check-output" ]] && touch "${LOCAL_FILES}/check-output"
  if ! grep -q "update -check" /etc/crontab; then
    echo "00 07,19 * * *  root  update -check >/dev/null 2>&1" >> /etc/crontab
  fi

  # Install a fetch tool if none present
  if ! command -v neofetch >/dev/null 2>&1 && ! command -v screenfetch >/dev/null 2>&1; then
    echo ""
    read -rp "Install neofetch [Enter] or screenfetch [s]? " _reply
    if [[ "${_reply,,}" == s ]]; then
      apt-get install screenfetch -y || true
    else
      apt-get install neofetch -y || true
    fi
  fi

  echo -e "${GN}Welcome screen installed.${CL}"
}

UNINSTALL() {
  if ! IS_INSTALLED; then
    echo -e "${OR}The Ultimate Updater is not installed.${CL}"
    return
  fi

  echo -e "\n${OR}Uninstall The Ultimate Updater${CL}\n"
  echo -e "${RD}This will remove all files under ${LOCAL_FILES}. Continue?${CL}"
  read -rp "Type Y/y to confirm: " _reply
  if [[ "${_reply}" =~ ^[Yy]$ ]]; then
    rm -f /usr/local/sbin/update
    rm -rf "${LOCAL_FILES}"
    if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
      rm -f /etc/update-motd.d/01-welcome-screen /etc/motd
      [[ -f /etc/motd.bak ]] && mv /etc/motd.bak /etc/motd
      mv /etc/crontab /etc/crontab.bak2
      [[ -f /etc/crontab.bak ]] && mv /etc/crontab.bak /etc/crontab
      mv /etc/crontab.bak2 /etc/crontab.bak
      read -rp "Also remove neofetch/screenfetch? [Y/y = yes]: " _reply
      if [[ "${_reply}" =~ ^[Yy]$ ]]; then
        apt-get remove screenfetch neofetch -y 2>/dev/null || true
        apt-get autoremove -y || true
      fi
    fi
    echo -e "${GN}The Ultimate Updater has been removed.${CL}"
    exit 0
  fi
}

set -e

EXIT() {
  local code=$?
  [[ ${code} -lt 2 ]] && exit 0
  rm -rf "${TEMP_FOLDER}" || true
  [[ ${code} -ne 0 ]] && echo -e "${RD}Install error — exit code: ${code}${CL}"
}
trap EXIT EXIT

HEADER_INFO
ARGUMENTS "$@"

if [[ "${COMMAND:-false}" != true ]]; then
  INSTALL
fi

exit 0
