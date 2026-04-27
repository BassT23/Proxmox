#!/bin/bash

##########
# UI Lib #
##########

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
  if [[ "${INFO:-true}" != false ]]; then
    echo -e "\n              Mode: ${OR}${MODE}${CL}"
    if [[ "${HEADLESS:-false}" == true ]]; then
      echo -e "            Headless enabled"
    fi
  fi
  CHECK_ROOT
  CHECK_INTERNET
  if [[ "${INFO:-true}" != false && "${CHECK_VERSION:-true}" == true ]]; then
    VERSION_CHECK
  else
    echo
  fi
  [[ "${TAG_LOG:-}" == true ]] && type print_tag_log >/dev/null 2>&1 && { print_tag_log; echo; } || true
}

ui_section() { echo -e "\n${OR}--- $* ---${CL}"; }
ui_info()    { echo -e "ℹ  ${OR}$*${CL}"; }
ui_ok()      { echo -e "✅ ${GN}$*${CL}"; }
ui_warn()    { echo -e "⚠  ${OR}$*${CL}"; }
ui_error()   { echo -e "❌ ${RD}$*${CL}"; }
ui_skip()    { echo -e "⏩ ${BL}$*${CL}"; }
ui_update()  { echo -e "🔄 ${GN}$*${CL}"; }
ui_start()   { echo -e " ▶ ${GN}$*${CL}"; }
ui_stop()    { echo -e "⏹  ${GN}$*${CL}"; }
ui_backup()  { echo -e "💾 ${OR}$*${CL}"; }
ui_wait()    { echo -e "⏳ ${OR}$*${CL}"; }
ui_debug()   { [[ "${DEBUG:-false}" == true ]] && echo -e "${BL}[DEBUG]${CL} $*" || true; }
