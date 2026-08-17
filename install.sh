#!/bin/bash

###########
# Install #
###########

# shellcheck disable=SC2034

VERSION="2.1"

# Branch

BRANCH="${UU_TARGET_BRANCH:-beta}"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
case "$BRANCH" in
  master|beta|develop) ;;
  *) echo "Unsupported update branch: $BRANCH" >&2; exit 2 ;;
esac
export UU_TARGET_BRANCH="$BRANCH"
WEB_UI_PORT_SCRIPT="$LOCAL_FILES/web-ui-port.sh"
HARDCORE_TEST_SCRIPT="$LOCAL_FILES/hardcore-test.sh"
WEB_SERVICE_NAME="ultimate-updater-web.service"
WEB_SERVICE_PATH="/etc/systemd/system/$WEB_SERVICE_NAME"
TEMP_FOLDER="/root/Ultimate-Updater-Temp"
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH"

#Colors
BL="\e[36m"
OR="\e[1;33m"
RD="\e[1;91m"
GN="\e[1;92m"
CL="\e[0m"

#Header
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
  echo -e "\n \
      *** Install and/or Update *** \n \
      ***   Version :   $VERSION   *** \n"
  CHECK_ROOT
}

#Check root
CHECK_ROOT () {
  if [[ "$EUID" -ne 0 ]]; then
      echo -e >&2 "⚠${RD:-} --- Please run this as root --- ⚠${CL:-}";
      exit 1
  fi
}

SETUP_WEB_SERVICE () {
  local action="${1:-start}" port

  if [[ ! -f "$WEB_SERVICE_PATH" || ! -f "$LOCAL_FILES/web-ui/server.py" ]]; then
    echo -e "⚠${OR:-} Web UI service files are incomplete${CL:-}" >&2
    return 1
  fi
  [[ -x "$WEB_UI_PORT_SCRIPT" ]] || { echo "Web UI port helper is missing: $WEB_UI_PORT_SCRIPT" >&2; return 1; }
  "$WEB_UI_PORT_SCRIPT" ensure >/dev/null || return 1
  "$WEB_UI_PORT_SCRIPT" check >/dev/null || return 1

  systemctl daemon-reload
  systemctl enable "$WEB_SERVICE_NAME" >/dev/null || return 1
  if [[ "$action" == restart ]]; then
    systemctl restart "$WEB_SERVICE_NAME" || return 1
  else
    systemctl start "$WEB_SERVICE_NAME" || return 1
  fi
  port=$("$WEB_UI_PORT_SCRIPT" get) || return 1
  printf '✅ Web UI ready on port %s.\n' "$port"
}

ARGUMENTS () {
  while test $# -gt -0; do
    ARGUMENT="$1"
    case "$ARGUMENT" in
      -h|--help)
        USAGE
        exit 0
        ;;
      status)
        STATUS
        ;;
      install)
        COMMAND=true
        INSTALL
        WELCOME_SCREEN
        EXIT
        ;;
      update)
        COMMAND=true
        UPDATE
        EXIT
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        EXIT
        ;;
      welcome)
        WELCOME_SCREEN
        EXIT
        ;;
      *)
        echo -e "❌${RD:-} Error: Got an unexpected argument \"$ARGUMENT\"${CL:-}\n";
        USAGE;
        exit 1;
        ;;
    esac
  done
}

USAGE () {
  if [[ $SILENT != true ]]; then
    echo -e "Usage: $0 {COMMAND}\n"
    echo -e "{COMMAND}:"
    echo -e "=========="
    echo -e "  -h --help            Show help menu"
    echo -e "  status               Check current installation status"
    echo -e "  install              Install The Ultimate Updater"
    echo -e "  welcome              Install or Uninstall Welcome Screen"
    echo -e "  uninstall            Uninstall The Ultimate Updater"
    echo -e "  update               Update The Ultimate Updater\n"
    echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
  fi
}

IS_INSTALLED () {
  if [ -f "/usr/local/sbin/update" ]; then
    true
  else
    false
  fi
}

STATUS () {
  if [[ $SILENT != true ]]; then
    echo -e "The Ultimate Updater"
    if IS_INSTALLED; then
      echo -e "Status: ${GN:-}present${CL:-}\n"
    else
      echo -e "Status: ${RD:-}not present${CL:-}\n"
    fi
  fi
  if IS_INSTALLED; then exit 0; else exit 1; fi
}

INFORMATION () {
  if [[ -d /root/Proxmox-Updater/ ]]; then
    echo -e "\n${RD:-} --- ATTENTION! ---\n Because of name and directory changing, you will need an reboot of the node, after the update\n\n${BL:-} Do you want to proceed?${CL:-}"
    read -p " Type [Y/y] or Enter for yes - anything else will exit: " -r
      if ! [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        exit 1
      fi
  fi
}

OLD_FILESYSTEM_CHECK () {
  if [[ -d /root/Proxmox-Updater/ ]]; then
    mv /root/Proxmox-Updater/ $LOCAL_FILES/
    if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
      mv /etc/crontab /etc/crontab.bak_name_change
      cp /etc/crontab.bak /etc/crontab
      echo "00 07,19 * * *  root    $LOCAL_FILES/check-updates.sh" >> /etc/crontab
    fi
  fi
  if [[ -d /root/Ultimative-Updater/ ]]; then
    if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
      mv /etc/crontab /etc/crontab.bak_name_change
      cp /etc/crontab.bak /etc/crontab
      echo "00 07,19 * * *  root    $LOCAL_FILES/check-updates.sh" >> /etc/crontab
    fi
  fi
  if [ -d "/root/Ultimative-Update-Scripts" ]; then
    echo -e "${RD:-}Ultimate-Updater has changed directory's, so the old directory\n\
/root/Update-Scripts will be delete.${CL:-}\n\
${OR:-}Is it OK for you, or want to backup your files first?${CL:-}\n"
    read -p "Type [Y/y] for DELETE - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf /root/Update-Proxmox-Scripts || true
      bash <(curl -s "$SERVER_URL/install.sh") update
    else
      exit 0
    fi
  fi
  # Delete old files (old filesystem)
  rm -rf /etc/update-motd.d/01-updater || true
  rm -rf /etc/update-motd.d/01-updater.bak || true
  # Check and renew to new structure
  if [[ -f /usr/local/bin/update ]] && [[ ! -f /usr/local/sbin/update ]]; then
    curl  -s -L "https://raw.githubusercontent.com/BassT23/Proxmox/$BRANCH/update.sh" > "$LOCAL_FILES/update.sh"
    chmod 750 "$LOCAL_FILES/update.sh"
    ln -sf "$LOCAL_FILES/update.sh" /usr/local/sbin/update
    rm /usr/local/bin/update
    NEED_REBOOT=true
  fi
}

INSTALL () {
  echo -e "\nℹ ${GN:-} Installing The Ultimate Updater${CL:-}\n"
  if [ -f "/usr/local/sbin/update" ]; then
    echo -e "${OR:-}The Ultimate Updater is already installed.${CL:-}"
    read -p "Should I update for you? Type [Y/y] or Enter for yes - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
      bash <(curl -s "$SERVER_URL/install.sh") update
    else
      echo -e "${OR:-}\nBye\n${CL:-}"
      exit 0
    fi
  else
    mkdir -p $LOCAL_FILES/exit
    mkdir -p $LOCAL_FILES/VMs
    mkdir -p $LOCAL_FILES/scripts.d/000
    # Download latest release
    if ! [[ -d $TEMP_FOLDER ]];then mkdir $TEMP_FOLDER; fi
      if [[ "$BRANCH" == master ]]; then
        curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O $TEMP_FOLDER/ultimate-updater.tar.gz
      else
        curl -s -L "https://github.com/BassT23/Proxmox/tarball/$BRANCH" > "$TEMP_FOLDER/ultimate-updater.tar.gz"
      fi
      tar -zxf $TEMP_FOLDER/ultimate-updater.tar.gz -C $TEMP_FOLDER
      rm -rf $TEMP_FOLDER/ultimate-updater.tar.gz || true
      TEMP_FILES=$TEMP_FOLDER
    # Copy files
    cp "$TEMP_FILES"/update.sh $LOCAL_FILES/update.sh
    chmod 750 $LOCAL_FILES/update.sh
    ln -sf $LOCAL_FILES/update.sh /usr/local/sbin/update
    cp "$TEMP_FILES"/VMs/example $LOCAL_FILES/VMs/example
    cp "$TEMP_FILES"/exit/* $LOCAL_FILES/exit/
    chmod -R +x "$LOCAL_FILES"/exit/*.sh
    cp "$TEMP_FILES"/scripts.d/000/* $LOCAL_FILES/scripts.d/000/
    cp "$TEMP_FILES"/update-extras.sh $LOCAL_FILES/update-extras.sh
    cp "$TEMP_FILES"/check-updates.sh $LOCAL_FILES/check-updates.sh
    chmod -R +x "$LOCAL_FILES"/check-updates.sh
    cp "$TEMP_FILES"/tag-filter.sh $LOCAL_FILES/tag-filter.sh
    cp "$TEMP_FILES"/target-inventory.sh $LOCAL_FILES/target-inventory.sh
    chmod 750 $LOCAL_FILES/target-inventory.sh
    cp "$TEMP_FILES"/targets.conf $LOCAL_FILES/targets.conf
    cp "$TEMP_FILES"/status-model.sh $LOCAL_FILES/status-model.sh
    chmod 750 $LOCAL_FILES/status-model.sh
    cp "$TEMP_FILES"/windows-update.sh $LOCAL_FILES/windows-update.sh
    chmod 750 $LOCAL_FILES/windows-update.sh
    cp "$TEMP_FILES"/target-runtime.sh $LOCAL_FILES/target-runtime.sh
    cp "$TEMP_FILES"/config-merge.sh $LOCAL_FILES/config-merge.sh
    chmod 750 $LOCAL_FILES/config-merge.sh
    if [[ -f "$TEMP_FILES"/cluster-target.sh ]]; then
      cp "$TEMP_FILES"/cluster-target.sh $LOCAL_FILES/cluster-target.sh
      chmod 750 $LOCAL_FILES/cluster-target.sh
    fi
    if [[ -f "$TEMP_FILES"/external-apt.sh ]]; then
      cp "$TEMP_FILES"/external-apt.sh $LOCAL_FILES/external-apt.sh
      chmod 750 $LOCAL_FILES/external-apt.sh
    fi
    if [[ -f "$TEMP_FILES"/external-helper.sh ]]; then
      cp "$TEMP_FILES"/external-helper.sh $LOCAL_FILES/external-helper.sh
      chmod 750 $LOCAL_FILES/external-helper.sh
    fi
    if [[ -f "$TEMP_FILES"/external-bootstrap.sh ]]; then
      cp "$TEMP_FILES"/external-bootstrap.sh $LOCAL_FILES/external-bootstrap.sh
      chmod 750 $LOCAL_FILES/external-bootstrap.sh
    fi
    if [[ -f "$TEMP_FILES"/external-config.sh ]]; then
      cp "$TEMP_FILES"/external-config.sh $LOCAL_FILES/external-config.sh
      chmod 750 $LOCAL_FILES/external-config.sh
    fi
    if [[ -f "$TEMP_FILES"/external-settings.sh ]]; then
      cp "$TEMP_FILES"/external-settings.sh $LOCAL_FILES/external-settings.sh
      chmod 750 $LOCAL_FILES/external-settings.sh
    fi
    cp "$TEMP_FILES"/web-ui-port.sh $LOCAL_FILES/web-ui-port.sh
    chmod 750 $LOCAL_FILES/web-ui-port.sh
    if [[ -f "$TEMP_FILES"/hardcore-test.sh ]]; then
      cp "$TEMP_FILES"/hardcore-test.sh $LOCAL_FILES/hardcore-test.sh
      chmod 750 $LOCAL_FILES/hardcore-test.sh
    fi
    if [[ -f "$TEMP_FILES"/external-backup-safety.sh ]]; then
      cp "$TEMP_FILES"/external-backup-safety.sh $LOCAL_FILES/external-backup-safety.sh
      chmod 750 $LOCAL_FILES/external-backup-safety.sh
    fi
    if [[ -f "$TEMP_FILES"/legacy-migrate.sh ]]; then
      cp "$TEMP_FILES"/legacy-migrate.sh $LOCAL_FILES/legacy-migrate.sh
      chmod 750 $LOCAL_FILES/legacy-migrate.sh
    fi
    chmod 750 $LOCAL_FILES/target-runtime.sh
    cp "$TEMP_FILES"/ultimate-updater $LOCAL_FILES/ultimate-updater
    chmod 750 $LOCAL_FILES/ultimate-updater
    ln -sf $LOCAL_FILES/ultimate-updater /usr/local/sbin/ultimate-updater
    if [[ -f "$TEMP_FILES"/web-auth.sh ]]; then
      install -m 0750 "$TEMP_FILES"/web-auth.sh "$LOCAL_FILES/web-auth.sh"
      ln -sf "$LOCAL_FILES/web-auth.sh" /usr/local/sbin/ultimate-updater-web-auth
    fi
    cp "$TEMP_FILES"/job-runner.sh $LOCAL_FILES/job-runner.sh
    chmod 750 $LOCAL_FILES/job-runner.sh
    if [[ -f "$TEMP_FILES"/global-update.sh ]]; then
      cp "$TEMP_FILES"/global-update.sh $LOCAL_FILES/global-update.sh
      chmod 750 $LOCAL_FILES/global-update.sh
    fi
    if [[ -f "$TEMP_FILES"/external-selection.sh ]]; then
      cp "$TEMP_FILES"/external-selection.sh $LOCAL_FILES/external-selection.sh
      chmod 750 $LOCAL_FILES/external-selection.sh
    fi
    mkdir -p "$LOCAL_FILES/web-ui"
    cp "$TEMP_FILES"/web-ui/server.py "$LOCAL_FILES/web-ui/server.py"
    chmod 750 "$LOCAL_FILES/web-ui/server.py"
    if [[ -f "$TEMP_FILES/web-ui/pam_auth.py" ]]; then
      install -m 0640 "$TEMP_FILES/web-ui/pam_auth.py" "$LOCAL_FILES/web-ui/pam_auth.py"
    fi
    mkdir -p "$LOCAL_FILES/web-ui/assets"
    for UI_ASSET in ultimate-updater-header.png ultimate-updater-icon.png favicon.png; do
      if [[ -f "$TEMP_FILES/web-ui/assets/$UI_ASSET" ]]; then
        install -m 0644 "$TEMP_FILES/web-ui/assets/$UI_ASSET" "$LOCAL_FILES/web-ui/assets/$UI_ASSET"
      fi
    done
    install -m 0644 "$TEMP_FILES/$WEB_SERVICE_NAME" "$WEB_SERVICE_PATH"
    cp "$TEMP_FILES"/update.conf $LOCAL_FILES/update.conf
    if [[ -f "$TEMP_FILES"/update.conf.dist ]]; then
      cp "$TEMP_FILES"/update.conf.dist $LOCAL_FILES/update.conf.dist
    else
      cp "$TEMP_FILES"/update.conf $LOCAL_FILES/update.conf.dist
    fi
    cp "$TEMP_FILES"/README.md $LOCAL_FILES/README.md
    SETUP_WEB_SERVICE start
    echo -e "${OR:-}Finished. Run The Ultimate Updater with 'update'.${CL:-}"
    echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
    echo -e "${OR:-}Also want to install the Welcome-Screen?${CL:-}"
    read -p "Type [Y/y] or Enter for yes - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
      WELCOME_SCREEN_INSTALL
    fi
    rm -rf $TEMP_FOLDER || true
  fi
}

UPDATE () {
  # File replacement during a self-update must never ask on a terminal.
  # update.conf is handled separately by MERGE_UPDATE_CONFIG below.
  local upgrade_noninteractive="${UU_NONINTERACTIVE:-false}"
  export UU_NONINTERACTIVE=true
  INFORMATION
  OLD_FILESYSTEM_CHECK
  if [ -f "/usr/local/sbin/update" ]; then
    # Update
    echo -e "\nℹ ${GN:-} Updating script ...${CL:-}\n"
    # Cleaning
    rm -rf "$TEMP_FOLDER" || true
    # Download files
    if ! [[ -d $TEMP_FOLDER ]]; then mkdir $TEMP_FOLDER; fi
    if [[ "$BRANCH" == master ]]; then
      curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O $TEMP_FOLDER/ultimate-updater.tar.gz
    elif [[ "$BRANCH" == beta || "$BRANCH" == develop ]]; then
      curl -s -L "https://github.com/BassT23/Proxmox/tarball/$BRANCH" > $TEMP_FOLDER/ultimate-updater.tar.gz
    fi
    tar -zxf $TEMP_FOLDER/ultimate-updater.tar.gz -C $TEMP_FOLDER
    rm -rf $TEMP_FOLDER/ultimate-updater.tar.gz || true
    if [[ "$BRANCH" == master ]]; then
      TEMP_FILES=$TEMP_FOLDER
    else
      TEMP_FILES=$TEMP_FOLDER/$(ls $TEMP_FOLDER)
    fi
    installed_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$LOCAL_FILES/update.sh" 2>/dev/null || true)
    target_version=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$TEMP_FILES/update.sh" 2>/dev/null || true)
    installed_major=''
    installed_minor=''
    target_major=''
    target_minor=''
    if [[ "$installed_version" =~ ^([0-9]+)\.([0-9]+)([.]|$) ]]; then
      installed_major=${BASH_REMATCH[1]}
      installed_minor=${BASH_REMATCH[2]}
    fi
    if [[ "$target_version" =~ ^([0-9]+)\.([0-9]+)([.]|$) ]]; then
      target_major=${BASH_REMATCH[1]}
      target_minor=${BASH_REMATCH[2]}
    fi
    if [[ -n "$installed_major" && -n "$target_major" ]] &&
      { (( installed_major < 5 )) || (( installed_major == 5 && installed_minor <= 0 )); } &&
      { (( target_major > 5 )) || (( target_major == 5 && target_minor > 0 )); }; then
      if [[ ("$upgrade_noninteractive" == true && "${UU_UPGRADE_INTERACTIVE:-false}" != true) || ! -t 0 ]]; then
        echo -e "⚠${RD:-} Interactive confirmation required for upgrade from version 5.0 or earlier to $target_version. Run the upgrade manually.${CL:-}" >&2
        rm -rf "$TEMP_FOLDER" || true
        return 2
      fi
      echo -e "\n⚠${OR:-} Important upgrade notice${CL:-}\n"
      echo -e "You are upgrading Ultimate Updater from version 5.0 or earlier to $target_version.\n"
      echo -e "A restart of this Proxmox host is required to fully complete the Ultimate Updater migration."
      echo -e "The host will remain usable after the upgrade, but some Ultimate Updater components may not work reliably until the host has been restarted."
      echo -e "The updater will NOT restart the host automatically.\n"
      read -r -p "Continue with the upgrade? [Y/n] " upgrade_reply
      if [[ "$upgrade_reply" =~ ^[Nn] ]]; then
        echo "Upgrade cancelled by user."
        rm -rf "$TEMP_FOLDER" || true
        return 0
      fi
      UPGRADE_RESTART_REQUIRED=true
    fi
    # A 5.0 installation may not have config-merge.sh yet.  Validate and
    # use the helper from the downloaded target release before replacing any
    # installed files, so migration failure cannot leave a mixed installation.
    CONFIG_MERGE_SOURCE="$TEMP_FILES/config-merge.sh"
    if [[ ! -f "$CONFIG_MERGE_SOURCE" || ! -r "$CONFIG_MERGE_SOURCE" ]] ||
      ! bash -n "$CONFIG_MERGE_SOURCE"; then
      echo -e "❌${RD:-} Target release has no valid configuration migration helper; existing installation was left unchanged.${CL:-}" >&2
      rm -rf "$TEMP_FOLDER" || true
      return 2
    fi
    if [[ -f "$TEMP_FILES/update.conf.dist" ]]; then
      CONFIG_DIST_SOURCE="$TEMP_FILES/update.conf.dist"
    else
      CONFIG_DIST_SOURCE="$TEMP_FILES/update.conf"
    fi
    if [[ ! -f "$CONFIG_DIST_SOURCE" ]]; then
      echo -e "❌${RD:-} Target release is missing its configuration defaults; existing installation was left unchanged.${CL:-}" >&2
      rm -rf "$TEMP_FOLDER" || true
      return 2
    fi
    # shellcheck disable=SC1090
    source "$CONFIG_MERGE_SOURCE" || {
      echo -e "❌${RD:-} Configuration migration helper could not be loaded; existing installation was left unchanged.${CL:-}" >&2
      rm -rf "$TEMP_FOLDER" || true
      return 2
    }
    if [[ -f "$LOCAL_FILES/update.conf" ]]; then
      if ! MERGE_UPDATE_CONFIG "$LOCAL_FILES/update.conf" "$CONFIG_DIST_SOURCE" "$BRANCH"; then
        echo -e "❌${RD:-} Configuration migration failed; the existing installation was left unchanged.${CL:-}" >&2
        rm -rf "$TEMP_FOLDER" || true
        return 2
      fi
    else
      cp "$CONFIG_DIST_SOURCE" "$LOCAL_FILES/update.conf"
    fi
    # Copy files
    mv "$TEMP_FILES"/update.sh $LOCAL_FILES/update.sh
    chmod 750 $LOCAL_FILES/update.sh
    mv "$TEMP_FILES"/README.md $LOCAL_FILES/README.md
    mv "$TEMP_FILES"/tag-filter.sh $LOCAL_FILES/tag-filter.sh
    if [[ -f "$TEMP_FILES"/target-inventory.sh ]]; then
      mv "$TEMP_FILES"/target-inventory.sh $LOCAL_FILES/target-inventory.sh
      chmod 750 $LOCAL_FILES/target-inventory.sh
    fi
    if [[ -f "$TEMP_FILES"/status-model.sh ]]; then
      mv "$TEMP_FILES"/status-model.sh $LOCAL_FILES/status-model.sh
      chmod 750 $LOCAL_FILES/status-model.sh
    fi
    if [[ -f "$TEMP_FILES"/windows-update.sh ]]; then
      mv "$TEMP_FILES"/windows-update.sh $LOCAL_FILES/windows-update.sh
      chmod 750 $LOCAL_FILES/windows-update.sh
    fi
    if [[ -f "$TEMP_FILES"/target-runtime.sh ]]; then
      mv "$TEMP_FILES"/target-runtime.sh $LOCAL_FILES/target-runtime.sh
      chmod 750 $LOCAL_FILES/target-runtime.sh
    fi
    if [[ -f "$TEMP_FILES"/cluster-target.sh ]]; then
      mv "$TEMP_FILES"/cluster-target.sh $LOCAL_FILES/cluster-target.sh
      chmod 750 $LOCAL_FILES/cluster-target.sh
    fi
    if [[ -f "$TEMP_FILES"/external-apt.sh ]]; then
      mv "$TEMP_FILES"/external-apt.sh $LOCAL_FILES/external-apt.sh
      chmod 750 $LOCAL_FILES/external-apt.sh
    fi
    if [[ -f "$TEMP_FILES"/external-helper.sh ]]; then
      mv "$TEMP_FILES"/external-helper.sh $LOCAL_FILES/external-helper.sh
      chmod 750 $LOCAL_FILES/external-helper.sh
    fi
    if [[ -f "$TEMP_FILES"/external-bootstrap.sh ]]; then
      mv "$TEMP_FILES"/external-bootstrap.sh $LOCAL_FILES/external-bootstrap.sh
      chmod 750 $LOCAL_FILES/external-bootstrap.sh
    fi
    if [[ -f "$TEMP_FILES"/external-config.sh ]]; then
      mv "$TEMP_FILES"/external-config.sh $LOCAL_FILES/external-config.sh
      chmod 750 $LOCAL_FILES/external-config.sh
    fi
    if [[ -f "$TEMP_FILES"/external-settings.sh ]]; then
      mv "$TEMP_FILES"/external-settings.sh $LOCAL_FILES/external-settings.sh
      chmod 750 $LOCAL_FILES/external-settings.sh
    fi
    if [[ -f "$TEMP_FILES"/web-ui-port.sh ]]; then
      mv "$TEMP_FILES"/web-ui-port.sh $LOCAL_FILES/web-ui-port.sh
      chmod 750 $LOCAL_FILES/web-ui-port.sh
    fi
    if [[ -f "$TEMP_FILES"/hardcore-test.sh ]]; then
      mv "$TEMP_FILES"/hardcore-test.sh $LOCAL_FILES/hardcore-test.sh
      chmod 750 $LOCAL_FILES/hardcore-test.sh
    fi
    if [[ -f "$TEMP_FILES"/external-backup-safety.sh ]]; then
      mv "$TEMP_FILES"/external-backup-safety.sh $LOCAL_FILES/external-backup-safety.sh
      chmod 750 $LOCAL_FILES/external-backup-safety.sh
    fi
    if [[ -f "$TEMP_FILES"/legacy-migrate.sh ]]; then
      mv "$TEMP_FILES"/legacy-migrate.sh $LOCAL_FILES/legacy-migrate.sh
      chmod 750 $LOCAL_FILES/legacy-migrate.sh
    fi
    if [[ -f "$TEMP_FILES"/ultimate-updater ]]; then
      mv "$TEMP_FILES"/ultimate-updater $LOCAL_FILES/ultimate-updater
      chmod 750 $LOCAL_FILES/ultimate-updater
      ln -sf $LOCAL_FILES/ultimate-updater /usr/local/sbin/ultimate-updater
    fi
    if [[ -f "$TEMP_FILES"/job-runner.sh ]]; then
      mv "$TEMP_FILES"/job-runner.sh $LOCAL_FILES/job-runner.sh
      chmod 750 $LOCAL_FILES/job-runner.sh
    fi
    if [[ -f "$TEMP_FILES"/global-update.sh ]]; then
      mv "$TEMP_FILES"/global-update.sh $LOCAL_FILES/global-update.sh
      chmod 750 $LOCAL_FILES/global-update.sh
    fi
    if [[ -f "$TEMP_FILES"/external-selection.sh ]]; then
      mv "$TEMP_FILES"/external-selection.sh $LOCAL_FILES/external-selection.sh
      chmod 750 $LOCAL_FILES/external-selection.sh
    fi
    if [[ -f "$TEMP_FILES"/config-merge.sh ]]; then
      mv "$TEMP_FILES"/config-merge.sh $LOCAL_FILES/config-merge.sh
      chmod 750 $LOCAL_FILES/config-merge.sh
    fi
    if [[ -f "$TEMP_FILES"/web-ui/server.py ]]; then
      mkdir -p "$LOCAL_FILES/web-ui"
      mv "$TEMP_FILES"/web-ui/server.py "$LOCAL_FILES/web-ui/server.py"
      chmod 750 "$LOCAL_FILES/web-ui/server.py"
    fi
    if [[ -f "$TEMP_FILES/web-ui/pam_auth.py" ]]; then
      install -m 0640 "$TEMP_FILES/web-ui/pam_auth.py" "$LOCAL_FILES/web-ui/pam_auth.py"
    fi
    if [[ -f "$TEMP_FILES"/web-auth.sh ]]; then
      install -m 0750 "$TEMP_FILES"/web-auth.sh "$LOCAL_FILES/web-auth.sh"
      ln -sf "$LOCAL_FILES/web-auth.sh" /usr/local/sbin/ultimate-updater-web-auth
    fi
    if [[ -f "$TEMP_FILES/web-ui/assets/ultimate-updater-header.png" || -f "$TEMP_FILES/web-ui/assets/ultimate-updater-icon.png" || -f "$TEMP_FILES/web-ui/assets/favicon.png" ]]; then
      mkdir -p "$LOCAL_FILES/web-ui/assets"
      for UI_ASSET in ultimate-updater-header.png ultimate-updater-icon.png favicon.png; do
        if [[ -f "$TEMP_FILES/web-ui/assets/$UI_ASSET" ]]; then
          install -m 0644 "$TEMP_FILES/web-ui/assets/$UI_ASSET" "$LOCAL_FILES/web-ui/assets/$UI_ASSET"
        fi
      done
    fi
    if [[ -f "$TEMP_FILES/$WEB_SERVICE_NAME" ]]; then
      install -m 0644 "$TEMP_FILES/$WEB_SERVICE_NAME" "$WEB_SERVICE_PATH"
    fi
    mv "$TEMP_FILES"/check-updates.sh $LOCAL_FILES/check-updates.sh
    chmod +x $LOCAL_FILES/check-updates.sh
    mv "$TEMP_FILES"/VMs/example $LOCAL_FILES/VMs/example
    if ! [[ -d "$LOCAL_FILES"/scripts.d/ ]]; then
      mkdir -p $LOCAL_FILES/scripts.d/000
      mv "$TEMP_FILES"/scripts.d/000/* $LOCAL_FILES/scripts.d/000/
      rm -rf "$TEMP_FILES"/scripts.d/ || true
    else
      rm -rf "$TEMP_FILES"/scripts.d/ || true
    fi
    if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
      mv "$TEMP_FILES"/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
      chmod +x /etc/update-motd.d/01-welcome-screen
      if [[ -f /usr/bin/neofetch ]] && [[ ! -f /usr/bin/screenfetch ]]; then
        echo -e "${OR:-}I detect neofetch was installed. On PVE9 neofetch is no more supported.${CL:-}"
        read -p " Should I install screenfetch for you instead? Type [Y/y] or Enter for yes - anything else will exit: " -r
        if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
          apt-get install screenfetch -y || true
        fi
      fi
      # change crontab entry
      CRON_FILE="/etc/crontab"
      BACKUP="/etc/crontab.bak.$(date +%Y%m%d-%H%M%S)"
      if grep -Eq "check-updates\.sh|update -check" "$CRON_FILE"; then
        if ! grep -q "RUN_FROM_CRON=true.*update -check" "$CRON_FILE"; then
          cp "$CRON_FILE" "$BACKUP"
          sed -i '/check-updates\.sh/d; /update -check/d' "$CRON_FILE"
          echo "00 06   * * *   root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1" >> "$CRON_FILE"
        fi
      fi
    else
      rm -rf "$TEMP_FILES"/welcome-screen.sh || true
      rm -rf "$TEMP_FILES"/check-updates.sh || true
    fi
    cp "$CONFIG_DIST_SOURCE" "$LOCAL_FILES/update.conf.dist"
    rm -f "$TEMP_FILES"/update.conf "$TEMP_FILES"/update.conf.dist
    # targets.conf is runtime inventory and must not be replaced by the
    # repository template after legacy migration or user edits.
    rm -f "$TEMP_FILES"/targets.conf
    rm -rf "$TEMP_FILES"/web-ui || true
    rm -f "$TEMP_FILES/$WEB_SERVICE_NAME"
    # Check if files are different
    rm -rf "$TEMP_FILES"/.github || true
    rm -rf "$TEMP_FILES"/VMs || true
    rm -rf "$TEMP_FILES"/LICENSE || true
    rm -rf "$TEMP_FILES"/README.md || true
    rm -rf "$TEMP_FILES"/change.log || true
    rm -rf "$TEMP_FILES"/install.sh || true
    rm -rf "$TEMP_FILES"/ssh.md || true
    rm -rf "$TEMP_FILES"/CODE_OF_CONDUCT.md || true
    rm -rf "$TEMP_FILES"/SECURITY.md || true
    rm -rf "$TEMP_FILES"/TESTING.md || true
    chmod -R +x "$TEMP_FILES"/exit/*.sh
    cd "$TEMP_FILES"
    FILES="*.* **/*.*"
    for FILE in $FILES
    do
     [[ "$FILE" == targets.conf ]] && continue
     CHECK_DIFF
    done
    if [[ -x "$LOCAL_FILES/legacy-migrate.sh" ]]; then
      if ! "$LOCAL_FILES/legacy-migrate.sh"; then
        echo -e "⚠️ ${OR:-}Legacy SSH migration needs attention; existing files were kept.${CL:-}" >&2
      fi
    fi
    SETUP_WEB_SERVICE restart
    rm -rf $TEMP_FOLDER || true
    echo -e "✅${GN:-} The Ultimate Updater updated successfully.${CL:-}"
    if [[ "$BRANCH" != master ]]; then echo -e "${OR:-}   Installed: $BRANCH version${CL:-}"; fi
    echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
    if [[ "$UPGRADE_RESTART_REQUIRED" == true ]]; then
      echo -e "${GN:-}✅ Upgrade completed successfully.${CL:-}"
      echo -e "${OR:-}⚠ A restart of this Proxmox host is required to fully complete the Ultimate Updater migration.\n  The host remains usable, but some Ultimate Updater components may not work reliably until it has been restarted.\n  Please restart the host when it is safe to do so.${CL:-}\n"
    elif [[ $NEED_REBOOT == true ]]; then
      echo -e "${RD:-}  Please reboot, to make The Ultimative Updater workable\n${CL:-}"
    fi
  else
    # Install, because no installation found
    echo -e "⚠${RD:-} The Ultimate Updater is not installed.\n\n${OR:-}Would you like to install it?${CL:-}"
    read -p "Type [Y/y] or Enter for yes - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
      bash <(curl -s "$SERVER_URL/install.sh")
    else
      echo -e "\n\nBye\n"
      exit 0
    fi
  fi
}

CHECK_DIFF () {
  if [[ ! -f "$LOCAL_FILES/$FILE" ]]; then
    mkdir -p "$(dirname "$LOCAL_FILES/$FILE")"
    mv "$TEMP_FILES/$FILE" "$LOCAL_FILES/$FILE"
    return
  fi

  if ! cmp -s "$TEMP_FILES"/"$FILE" "$LOCAL_FILES"/"$FILE"; then
    install_changed_file() {
      local backup="$LOCAL_FILES/$FILE"
      if [[ -e "$backup.bak" ]]; then
        backup="$backup.bak.$(date -u +%Y%m%d-%H%M%S)"
      else
        backup="$backup.bak"
      fi
      cp -p "$LOCAL_FILES/$FILE" "$backup"
      mv "$TEMP_FILES/$FILE" "$LOCAL_FILES/$FILE"
    }
    if [[ "${UU_NONINTERACTIVE:-false}" == true || ! -t 0 ]]; then
      echo -e "\nℹ${GN:-} Installed updated file without prompting; old file saved as '$FILE.bak' (or timestamped backup)${CL:-}\n"
      install_changed_file
      unset -f install_changed_file
      return 0
    fi
    echo -e "The file ${OR:-}$FILE${CL:-}\n \
 was modified (by you or by a script) since installation.\n \
   What would you like to do about it ?  Your options are:\n \
    Y or y  : install the package maintainer's version (old file will be saved as '$FILE.bak')\n \
    N or n  : keep your currently-installed version\n \
    S or s  : show the differences between the versions\n \
 The default action is to install new version and backup current file."
    read -p "*** $FILE (Y/y/N/n/S/s) [default=Y] ?" -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        echo -e "\nℹ ${GN:-} Installed server version and backed up old file${CL:-}\n"
        install_changed_file
      elif [[ $REPLY =~ ^[Nn]$ ]]; then
        echo -e "\nℹ${GN:-} Kept old file${CL:-}\n"
      elif [[ $REPLY =~ ^[Ss]$ ]]; then
        echo
        set +e
        diff "$TEMP_FILES"/"$FILE" "$LOCAL_FILES/$FILE"
        set -e
        echo -e "\n   What would you like to do about it ?  Your options are:\n \
    Y or y  : install the package maintainer's version (old file will be saved as '$FILE.bak')\n \
    N or n  : keep your currently-installed version\n \
 The default action is to install new version and backup current file."
        read -p "*** $FILE (Y/y/N/n) [default=Y] ?" -r
          if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
            echo -e "\nℹ ${GN:-} Installed server version and backed up old file${CL:-}\n"
            install_changed_file
          elif [[ $REPLY =~ ^[Nn]$ ]]; then
            echo -e "\nℹ ${GN:-} Kept old file${CL:-}\n"
          fi
      else
        echo -e "\n⏩${OR:-} Skip this file${CL:-}\n"
      fi
    unset -f install_changed_file
  fi
}

WELCOME_SCREEN () {
  if [[ $COMMAND != true ]]; then
    echo -e "\n${BL:-}[Info]${GN:-} Installing The Ultimate Updater Welcome-Screen${CL:-}\n"
    if ! [[ -d $TEMP_FOLDER ]];then mkdir $TEMP_FOLDER; fi
    curl -s "$SERVER_URL/welcome-screen.sh" > "$TEMP_FOLDER/welcome-screen.sh"
    if ! [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
      echo -e "${OR:-} Welcome-Screen is not installed${CL:-}\n"
      read -p "Would you like to install it also? Type [Y/y] or Enter for yes - anything else will skip: " -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        WELCOME_SCREEN_INSTALL
      fi
    else
      echo -e "${OR:-}  Welcome-Screen is already installed${CL:-}\n"
      read -p "Would you like to uninstall it? Type [Y/y] for yes - anything else will skip: " -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /etc/update-motd.d/01-welcome-screen || true
        rm -rf /etc/motd || true
        if [[ -f /etc/motd.bak ]]; then mv /etc/motd.bak /etc/motd; fi
        # delete crontab entry
        sed -i '\|update -check >/dev/null 2>&1|d' /etc/crontab
        echo -e "\n${BL:-} Welcome-Screen uninstalled${CL:-}\n\
${BL:-} crontab file restored (old one backed up as crontab.bak)${CL:-}\n"
      fi
    fi
    rm -rf $TEMP_FOLDER || true
  fi
}

WELCOME_SCREEN_INSTALL () {
  if [[ -f /etc/motd ]];then mv /etc/motd /etc/motd.bak; fi
  touch /etc/motd
  cp /etc/crontab /etc/crontab.bak
  cp $TEMP_FOLDER/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
  chmod +x /etc/update-motd.d/01-welcome-screen
  if ! [[ -f $LOCAL_FILES/check-output ]]; then touch $LOCAL_FILES/check-output; fi
  if ! grep -Eq "check-updates\.sh|update -check" /etc/crontab; then
    echo "00 06   * * *   root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1" >> /etc/crontab
  fi
  # Fetch tool install (neofetch or screenfetch)
  if ! command -v neofetch >/dev/null 2>&1 && ! command -v screenfetch >/dev/null 2>&1; then
    echo -e "${OR:-}  Install neofetch or screenfetch?${CL:-}"
    read -r -p "  Type [N/n] or Enter for neofetch, [S/s] for screenfetch: " REPLY
    if [[ $REPLY =~ ^[Ss]$ ]]; then
      apt-get install screenfetch -y || true
      echo -e "\n✅${GN:-} Welcome-Screen installed with screenfetch${CL:-}"
      return 0
    else
      apt-get install neofetch -y || true
      echo -e "\n✅${GN:-} Welcome-Screen installed with neofetch${CL:-}"
      return 0
    fi
  else
    echo -e "\n✅${GN:-} Welcome-Screen installed successfully${CL:-}"
  fi
}

UNINSTALL () {
  if [ -f /usr/local/sbin/update ]; then
    echo -e "\n${BL:-}[Info]${GN:-} Uninstall The Ultimate Updater${CL:-}\n"
    echo -e "${RD:-}Really want to remove The Ultimate Updater?${CL:-}"
    read -p "Type [Y/y] for yes - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm /usr/local/sbin/update
      systemctl disable --now "$WEB_SERVICE_NAME" || true
      rm -f "$WEB_SERVICE_PATH"
      systemctl daemon-reload
      rm -r $LOCAL_FILES
      if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
        rm -rf /etc/update-motd.d/01-welcome-screen
        rm -rf /etc/motd
        if [[ -f /etc/motd.bak ]]; then
          mv /etc/motd.bak /etc/motd
        fi
        mv /etc/crontab /etc/crontab.bak2
        mv /etc/crontab.bak /etc/crontab
        mv /etc/crontab.bak2 /etc/crontab.bak
        echo -e "${BL:-}Should fetch be uninstalled also?${CL:-}"
        read -p "Type [Y/y] for yes - anything else will skip: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          apt-get remove screenfetch -y || true
          apt-get remove neofetch -y || true
          apt-get autoremove -y || true
          echo -e "\n${BL:-} fetch uninstalled${CL:-}"
        fi
      fi
      echo -e "\n\n${BL:-} The Ultimate Updater has gone${CL:-}\n\
${BL:-} crontab file restored (old one backed up as crontab.bak)${CL:-}\n"
      exit 0
    fi
  else
    echo -e "⚠${RD:-} The Ultimate Updater is not installed.${CL:-}\n"
  fi
}

#Error/Exit
set -e
EXIT () {
  EXIT_CODE=$?
  # Install Finish
  if  [[ $EXIT_CODE -lt 2 ]]; then
    exit 0
  elif [[ $EXIT_CODE != "0" ]]; then
    rm -rf $TEMP_FOLDER || true
    echo -e "❌${RD:-} Error during install --- Exit Code: $EXIT_CODE${CL:-}\n"
    exit "$EXIT_CODE"
  fi
}

# Exit Code
trap EXIT EXIT

#Install
HEADER_INFO
ARGUMENTS "$@"

# Run without commands
if [[ $COMMAND != true ]]; then
  INSTALL
fi

exit 0
