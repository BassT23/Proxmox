#!/bin/bash

###########
# Install #
###########

VERSION="1.6.6"

# Branch
BRANCH="development"

# Variable / Function
LOCAL_FILES="/root/Proxmox-Updater"
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
      https://github.com/BassT23/Proxmox"
  cat <<'EOF'
     ____
    / __ \_________  _  ______ ___  ____  _  __
   / /_/ / ___/ __ \| |/_/ __ `__ \/ __ \| |/_/
  / ____/ /  / /_/ />  </ / / / / / /_/ />  <
 /_/   /_/   \____/_/|_/_/ /_/ /_/\____/_/|_|
      __  __          __      __
     / / / /___  ____/ /___ _/ /____  ____
    / / / / __ \/ __  / __ `/ __/ _ \/ __/
   / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
   \____/ .___/\____/\____/\__/\___/_/
       /_/
EOF
  echo -e "\n \
      *** Install and/or Update *** \n \
      ***    Version :   $VERSION    *** \n"
  CHECK_ROOT
}

#Check root
CHECK_ROOT () {
  if [[ "$EUID" -ne 0 ]]; then
      echo -e >&2 "${RD}--- Please run this as root ---${CL}";
      exit 1
  fi
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
        echo -e "${RD}Error: Got an unexpected argument \"$ARGUMENT\"${CL}\n";
        USAGE;
        exit 1;
        ;;
    esac
#    shift
  done
}

USAGE () {
    if [[ $SILENT != true ]]; then
        echo -e "Usage: $0 {COMMAND}\n"
        echo -e "{COMMAND}:"
        echo -e "=========="
        echo -e "  -h --help            Show this help"
        echo -e "  status               Check current installation status"
        echo -e "  install              Install Proxmox-Updater"
        echo -e "  welcome              Install or Uninstall Welcome Screen"
        echo -e "  uninstall            Uninstall Proxmox-Updater"
        echo -e "  update               Update Proxmox-Updater\n"
        echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
}

isInstalled () {
    if [ -f "/usr/local/bin/update" ]; then
        true
    else
        false
    fi
}

STATUS () {
    if [[ $SILENT != true ]]; then
        echo -e "Proxmox-Updater"
        if isInstalled; then
            echo -e "Status: ${GN}present${CL}\n"
        else
            echo -e "Status: ${RD}not present${CL}\n"
        fi
    fi
    if isInstalled; then exit 0; else exit 1; fi
}

INSTALL () {
    echo -e "\n${BL}[Info]${GN} Installing Proxmox-Updater${CL}\n"
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "${OR}Proxmox-Updater is already installed.${CL}"
      read -p "Should I update for you? Type [Y/y] or Enter for yes - enything else will exit" -n 1 -r -s
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh) update
      else
        echo -e "${OR}\nBye\n${CL}"
        exit 0
      fi
    else
      mkdir -p /root/Proxmox-Updater/exit
      mkdir -p /root/Proxmox-Updater/VMs
      # Download latest release
      if ! [[ -d /root/Proxmox-Updater-Temp ]];then mkdir /root/Proxmox-Updater-Temp; fi
        curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz
        tar -zxf /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz -C /root/Proxmox-Updater-Temp
        rm -rf /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz || true
        TEMP_FILES=/root/Proxmox-Updater-Temp
      # Copy files
      cp "$TEMP_FILES"/update.sh /usr/local/bin/update
      chmod 750 /usr/local/bin/update
      cp "$TEMP_FILES"/VMs/example $LOCAL_FILES/VMs/example
      cp "$TEMP_FILES"/exit/* $LOCAL_FILES/exit/
      chmod -R +x "$LOCAL_FILES"/exit/*.sh
      cp "$TEMP_FILES"/update-extras.sh $LOCAL_FILES/update-extras.sh
      cp "$TEMP_FILES"/update.conf $LOCAL_FILES/update.conf
      echo -e "${OR}Finished. Run Proxmox-Updater with 'update'.${CL}"
      echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
      echo -e "${OR}Also want to install the Welcome-Screen?${CL}\n\
Type [Y/y] or Enter for yes - enything else will exit"
      read -p "" -n 1 -r -s
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        WELCOME_SCREEN_INSTALL
      fi
      rm -rf /root/Proxmox-Updater-Temp || true
    fi
}

UPDATE () {
    if [ -f "/usr/local/bin/update" ]; then
      # Check for old filesystem
      if [ -d "/root/Proxmox-Update-Scripts" ]; then
        echo -e "${RD}Proxmox-Updater has changed directorys, so the old directory\n\
/root/Update-Scripts will be delete.${CL}\n\
${OR}Is it OK for you, or want to backup your files first?${CL}\n"
        read -p "Type [Y/y] for DELETE - enything else will exit " -n 1 -r -s
        if [[ $REPLY =~ ^[Yy]$ ]]; then
          rm -rf /root/Update-Proxmox-Scripts || true
          bash <(curl -s $SERVER_URL/install.sh) update
        else
          exit 0
        fi
      else
        # Update
        echo -e "\n${BL}[Info]${GN} Updating script ...${CL}\n"
        # Download files
        if ! [[ -d /root/Proxmox-Updater-Temp ]]; then mkdir /root/Proxmox-Updater-Temp; fi
        if [[ "$BRANCH" == master ]]; then
          curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz
        elif [[ "$BRANCH" == beta ]]; then
          curl -s -L https://github.com/BassT23/Proxmox/tarball/beta > /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz
        elif [[ "$BRANCH" == development ]]; then
          curl -s -L https://github.com/BassT23/Proxmox/tarball/development > /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz
        fi
        tar -zxf /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz -C /root/Proxmox-Updater-Temp
        rm -rf /root/Proxmox-Updater-Temp/Proxmox-Updater.tar.gz || true
        if [[ "$BRANCH" == master ]]; then
          TEMP_FILES=/root/Proxmox-Updater-Temp
        else
          TEMP_FILES=/root/Proxmox-Updater-Temp/$(ls /root/Proxmox-Updater-Temp)
        fi
        # Copy files
        mv "$TEMP_FILES"/update.sh /usr/local/bin/update
        chmod 750 /usr/local/bin/update
        if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
          mv "$TEMP_FILES"/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
          chmod +x /etc/update-motd.d/01-welcome-screen
          mv "$TEMP_FILES"/check-updates.sh /root/Proxmox-Updater/check-updates.sh
          chmod +x /root/Proxmox-Updater/check-updates.sh
        else
          rm -rf "$TEMP_FILES"/welcome-screen.sh || true
          rm -rf "$TEMP_FILES"/check-updates.sh || true
        fi
        # Delete old files (old filesystem)
        rm -rf /etc/update-motd.d/01-updater || true
        rm -rf /etc/update-motd.d/01-updater.bak || true
        # Check if files are different
        rm -rf "$TEMP_FILES"/.github || true
        rm -rf "$TEMP_FILES"/VMs || true
        rm -rf "$TEMP_FILES"/LICENSE || true
        rm -rf "$TEMP_FILES"/README.md || true
        rm -rf "$TEMP_FILES"/change.log || true
        rm -rf "$TEMP_FILES"/install.sh || true
        rm -rf "$TEMP_FILES"/ssh.md || true
        chmod -R +x "$TEMP_FILES"/exit/*.sh
        cd "$TEMP_FILES"
        FILES="*.* **/*.*"
        for f in $FILES
        do
         CHECK_DIFF
        done
        rm -rf /root/Proxmox-Updater-Temp || true
        echo -e "${GN}Proxmox-Updater updated successfully.${CL}"
        if [[ "$BRANCH" != master ]]; then echo -e "${OR}  Installed: $BRANCH version${CL}"; fi
        echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
      fi
    else
      # Install, because no installation found
      echo -e "${RD}Proxmox-Updater is not installed.\n\n${OR}Would you like to install it?${CL}"
      read -p "Type [Y/y] or Enter for yes - enything else will exit" -n 1 -r -s
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh)
      else
        echo -e "\n\nBye\n"
        exit 0
      fi
    fi
}

CHECK_DIFF () {
  if ! cmp -s "$TEMP_FILES"/"$f" "$LOCAL_FILES"/"$f"; then
    echo -e "The file ${OR}$f${CL}\n \
 ==> Modified (by you or by a script) since installation.\n \
   What would you like to do about it ?  Your options are:\n \
    Y or y  : install the package maintainer's version (old file will be save as '$f.bak')\n \
    N or n  : keep your currently-installed version\n \
    S or s  : show the differences between the versions\n \
 The default action is to keep your current version.\n \
*** $f (Y/y/N/n/S/s) [default=Y] ? "
        read -p "" -n 1 -r -s
        if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
          echo -e "\n${BL}[Info]${GN} Installed server version and backed up old file${CL}\n"
          cp -f "$LOCAL_FILES"/"$f" "$LOCAL_FILES"/"$f".bak
          mv "$TEMP_FILES"/"$f" "$LOCAL_FILES"/"$f"
        elif [[ $REPLY =~ ^[Nn]$ ]]; then
          echo -e "\n${BL}[Info]${GN} Kept old file${CL}\n"
        elif [[ $REPLY =~ ^[Ss]$ ]]; then
          echo
          diff "$TEMP_FILES"/"$f" "$LOCAL_FILES/$f"
        else
          echo -e "\n${BL}[Info]${OR} Skip this file${CL}\n"
        fi
  fi
}

WELCOME_SCREEN () {
  if [[ $COMMAND != true ]]; then
    echo -e "\n${BL}[Info]${GN} Installing Proxmox-Updater Welcome-Screen${CL}\n"
    if ! [[ -d /root/Proxmox-Updater-Temp ]];then mkdir /root/Proxmox-Updater-Temp; fi
    curl -s $SERVER_URL/welcome-screen.sh > /root/Proxmox-Updater-Temp/welcome-screen.sh
    curl -s $SERVER_URL/check-updates.sh > /root/Proxmox-Updater-Temp/check-updates.sh
    if ! [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
      echo -e "${OR} Welcome-Screen is not installed${CL}\n"
      read -p "Would you like to install it also? Type [Y/y] or Enter for yes - enything else will skip" -n 1 -r -s && echo
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        WELCOME_SCREEN_INSTALL
      fi
    else
      echo -e "${OR}  Welcome-Screen is already installed${CL}\n"
      read -p "Would you like to uninstall it? Type [Y/y] for yes - enything else will skip" -n 1 -r -s && echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf /etc/update-motd.d/01-welcome-screen || true
        rm -rf /etc/motd || true
        if [[ -f /etc/motd.bak ]]; then mv /etc/motd.bak /etc/motd; fi
        #restore old crontab with info output
        mv /etc/crontab /etc/crontab.bak2
        mv /etc/crontab.bak /etc/crontab
        mv /etc/crontab.bak2 /etc/crontab.bak
        echo -e "\n${BL} Welcome-Screen uninstalled${CL}\n\
${BL} crontab file restored (old one backed up as crontab.bak)${CL}\n"
      fi
    fi
    rm -rf /root/Proxmox-Updater-Temp || true
  fi
}

WELCOME_SCREEN_INSTALL () {
  if [[ -f /etc/motd ]];then mv /etc/motd /etc/motd.bak; fi
  cp /etc/crontab /etc/crontab.bak
  touch /etc/motd
  if ! [[ -f /usr/bin/neofetch ]]; then apt-get install neofetch -y; fi
  cp /root/Proxmox-Updater-Temp/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
  cp /root/Proxmox-Updater-Temp/check-updates.sh /root/Proxmox-Updater/check-updates.sh
  chmod +x /etc/update-motd.d/01-welcome-screen
  chmod +x /root/Proxmox-Updater/check-updates.sh
  if ! [[ -f /root/Proxmox-Updater/check-output ]]; then touch /root/Proxmox-Updater/check-output; fi
  if ! grep -q "check-updates.sh" /etc/crontab; then
    echo "00 07,19 * * *  root    /root/Proxmox-Updater/check-updates.sh" >> /etc/crontab
  fi
  echo -e "\n${GN} Welcome-Screen installed${CL}"
}

UNINSTALL () {
  if [ -f /usr/local/bin/update ]; then
    echo -e "\n${BL}[Info]${GN} Uninstall Proxmox-Updater${CL}\n"
    echo -e "${RD}Really want to remove Proxmox-Updater?${CL}\n\
Type [Y/y] for yes - enything else will exit"
    read -p "" -n 1 -r -s
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm /usr/local/bin/update
      rm -r /root/Proxmox-Updater
      if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
        chmod -x /etc/update-motd.d/01-welcome-screen
        rm -rf /etc/motd
        if [[ -f /etc/motd.bak ]]; then
          mv /etc/motd.bak /etc/motd
        fi
        mv /etc/crontab /etc/crontab.bak2
        mv /etc/crontab.bak /etc/crontab
        mv /etc/crontab.bak2 /etc/crontab.bak
      fi
      echo -e "\n\n${BL} Proxmox-Updater removed${CL}\n\
${BL} crontab file restored (old one backed up as crontab.bak)${CL}\n"
      exit 0
    fi
  else
    echo -e "${RD}Proxmox-Updater is not installed.${CL}\n"
  fi
}

#Error/Exit
set -e
EXIT () {
  EXIT_CODE=$?
  # Install Finish
  if  [[ $EXIT_CODE -lt 2 ]]; then
    exit 0
#  elif [[ $EXIT_CODE == "1" ]]; then
#    exit 0
  elif [[ $EXIT_CODE != "0" ]]; then
    rm -rf /root/Proxmox-Updater-Temp || true
    echo -e "${RD}Error during install --- Exit Code: $EXIT_CODE${CL}\n"
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
