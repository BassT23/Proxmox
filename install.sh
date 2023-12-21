#!/bin/bash

###########
# Install #
###########

VERSION="1.7"

# Branch
BRANCH="develop"

# Variable / Function
LOCAL_FILES="/etc/ultimate-updater"
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
    / / / /___  ____/ /___ _/ /____  _____
   / / / / __ \/ __  / __ `/ __/ _ \/ ___/
  / /_/ / /_/ / /_/ / /_/ / /_/  __/ /
  \____/ ____/\____/\____/\__/\___/_/
      /_/     for Proxmox VE
EOF
  echo -e "\n \
      *** Install and/or Update *** \n \
      ***   Version :   $VERSION   *** \n"
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
        echo -e "  install              Install The Ultimate Updater"
        echo -e "  welcome              Install or Uninstall Welcome Screen"
        echo -e "  uninstall            Uninstall The Ultimate Updater"
        echo -e "  update               Update The Ultimate Updater\n"
        echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
}

isInstalled () {
    if [ -f "/usr/local/sbin/update" ]; then
        true
    else
        false
    fi
}

STATUS () {
    if [[ $SILENT != true ]]; then
        echo -e "The Ultimate Updater"
        if isInstalled; then
            echo -e "Status: ${GN}present${CL}\n"
        else
            echo -e "Status: ${RD}not present${CL}\n"
        fi
    fi
    if isInstalled; then exit 0; else exit 1; fi
}

OLD_FILESYSTEM_CHECK () {
  if [[ -d /root/Proxmox-Updater/ ]]; then mv /root/Proxmox-Updater/ $LOCAL_FILES/; fi
  if [[ -d /root/Ultimative-Updater/ ]]; then mv /root/Ultimative-Updater/ $LOCAL_FILES/; fi
  if [ -d "/root/Ultimative-Update-Scripts" ]; then
    echo -e "${RD}Ultimate-Updater has changed directorys, so the old directory\n\
/root/Update-Scripts will be delete.${CL}\n\
${OR}Is it OK for you, or want to backup your files first?${CL}\n"
    read -p "Type [Y/y] for DELETE - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm -rf /root/Update-Proxmox-Scripts || true
      bash <(curl -s $SERVER_URL/install.sh) update
    else
      exit 0
    fi
  fi
  # Delete old files (old filesystem)
  rm -rf /etc/update-motd.d/01-updater || true
  rm -rf /etc/update-motd.d/01-updater.bak || true
  # Check an renew to new structure
  if [[ -f /usr/local/bin/update ]] && [[ ! -f /usr/local/sbin/update ]]; then
    mv /usr/local/bin/update $LOCAL_FILES/update.sh
    ln -sf $LOCAL_FILES/update.sh /usr/local/sbin/update
    echo -e " Please reboot, to make The Ultimative Updater workable"
    exit 0
  fi
}

INSTALL () {
    echo -e "\n${BL}[Info]${GN} Installing The Ultimate Updater${CL}\n"
    if [ -f "/usr/local/sbin/update" ]; then
      echo -e "${OR}The Ultimate Updater is already installed.${CL}"
      read -p "Should I update for you? Type [Y/y] or Enter for yes - anything else will exit: " -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh) update
      else
        echo -e "${OR}\nBye\n${CL}"
        exit 0
      fi
    else
      mkdir -p $LOCAL_FILES/exit
      mkdir -p $LOCAL_FILES/VMs
      # Download latest release
      if ! [[ -d $TEMP_FOLDER ]];then mkdir $TEMP_FOLDER; fi
        curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O $TEMP_FOLDER/ultimate-updater.tar.gz
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
      cp "$TEMP_FILES"/update-extras.sh $LOCAL_FILES/update-extras.sh
      cp "$TEMP_FILES"/update.conf $LOCAL_FILES/update.conf
      echo -e "${OR}Finished. Run The Ultimate Updater with 'update'.${CL}"
      echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
      echo -e "${OR}Also want to install the Welcome-Screen?${CL}"
      read -p "Type [Y/y] or Enter for yes - anything else will exit: " -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        WELCOME_SCREEN_INSTALL
      fi
      rm -rf $TEMP_FOLDER || true
    fi
}

UPDATE () {
  OLD_FILESYSTEM_CHECK
  if [ -f "/usr/local/sbin/update" ]; then
    # Update
    echo -e "\n${BL}[Info]${GN} Updating script ...${CL}\n"
    # Download files
    if ! [[ -d $TEMP_FOLDER ]]; then mkdir $TEMP_FOLDER; fi
    if [[ "$BRANCH" == master ]]; then
      curl -s https://api.github.com/repos/BassT23/Proxmox/releases/latest | grep "browser_download_url" | cut -d : -f 2,3 | tr -d \" | wget -i - -q -O $TEMP_FOLDER/ultimate-updater.tar.gz
    elif [[ "$BRANCH" == beta ]]; then
      curl -s -L https://github.com/BassT23/Proxmox/tarball/beta > $TEMP_FOLDER/ultimate-updater.tar.gz
    elif [[ "$BRANCH" == develop ]]; then
      curl -s -L https://github.com/BassT23/Proxmox/tarball/develop > $TEMP_FOLDER/ultimate-updater.tar.gz
    fi
    tar -zxf $TEMP_FOLDER/ultimate-updater.tar.gz -C $TEMP_FOLDER
    rm -rf $TEMP_FOLDER/ultimate-updater.tar.gz || true
    if [[ "$BRANCH" == master ]]; then
      TEMP_FILES=$TEMP_FOLDER
    else
      TEMP_FILES=$TEMP_FOLDER/$(ls $TEMP_FOLDER)
    fi
    # Copy files
    mv "$TEMP_FILES"/update.sh $LOCAL_FILES/update.sh
    chmod 750 $LOCAL_FILES/update.sh
    if [[ -f /etc/update-motd.d/01-welcome-screen ]]; then
      mv "$TEMP_FILES"/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
      chmod +x /etc/update-motd.d/01-welcome-screen
      mv "$TEMP_FILES"/check-updates.sh $LOCAL_FILES/check-updates.sh
      chmod +x $LOCAL_FILES/check-updates.sh
    else
      rm -rf "$TEMP_FILES"/welcome-screen.sh || true
      rm -rf "$TEMP_FILES"/check-updates.sh || true
    fi
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
    rm -rf $TEMP_FOLDER || true
    echo -e "${GN}The Ultimate Updater updated successfully.${CL}"
    if [[ "$BRANCH" != master ]]; then echo -e "${OR}  Installed: $BRANCH version${CL}"; fi
    echo -e "For infos and warnings please check the readme under <https://github.com/BassT23/Proxmox>\n"
  else
    # Install, because no installation found
    echo -e "${RD}The Ultimate Updater is not installed.\n\n${OR}Would you like to install it?${CL}"
    read -p "Type [Y/y] or Enter for yes - anything else will exit: " -r
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
 The default action is to install new version and backup current file."
    read -p "*** $f (Y/y/N/n/S/s) [default=Y] ?" -r
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
    echo -e "\n${BL}[Info]${GN} Installing The Ultimate Updater Welcome-Screen${CL}\n"
    if ! [[ -d $TEMP_FOLDER ]];then mkdir $TEMP_FOLDER; fi
    curl -s $SERVER_URL/welcome-screen.sh > $TEMP_FOLDER/welcome-screen.sh
    curl -s $SERVER_URL/check-updates.sh > $TEMP_FOLDER/check-updates.sh
    if ! [[ -f "/etc/update-motd.d/01-welcome-screen" && -x "/etc/update-motd.d/01-welcome-screen" ]]; then
      echo -e "${OR} Welcome-Screen is not installed${CL}\n"
      read -p "Would you like to install it also? Type [Y/y] or Enter for yes - anything else will skip: " -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        WELCOME_SCREEN_INSTALL
      fi
    else
      echo -e "${OR}  Welcome-Screen is already installed${CL}\n"
      read -p "Would you like to uninstall it? Type [Y/y] for yes - anything else will skip: " -r
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
    rm -rf $TEMP_FOLDER || true
  fi
}

WELCOME_SCREEN_INSTALL () {
  if [[ -f /etc/motd ]];then mv /etc/motd /etc/motd.bak; fi
  touch /etc/motd
  cp /etc/crontab /etc/crontab.bak
  cp $TEMP_FOLDER/welcome-screen.sh /etc/update-motd.d/01-welcome-screen
  cp $TEMP_FOLDER/check-updates.sh $LOCAL_FILES/check-updates.sh
  chmod +x /etc/update-motd.d/01-welcome-screen
  chmod +x $LOCAL_FILES/check-updates.sh
  if ! [[ -f $LOCAL_FILES/check-output ]]; then touch $LOCAL_FILES/check-output; fi
  if ! grep -q "check-updates.sh" /etc/crontab; then
    echo "00 07,19 * * *  root    $LOCAL_FILES/check-updates.sh" >> /etc/crontab
  fi
  echo -e "${OR}  with or without neofetch?${CL}"
  read -p "  Type [Y/y] or Enter for install neofetch - anything else will install without neofetch: " -r
  if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
    if ! [[ -f /usr/bin/neofetch ]]; then apt-get install neofetch -y; fi
    echo -e "\n${GN} Welcome-Screen installed with neofetch${CL}"
  else
    echo -e "\n${GN} Welcome-Screen installed without neofetch${CL}"
  fi
}

UNINSTALL () {
  if [ -f /usr/local/sbin/update ]; then
    echo -e "\n${BL}[Info]${GN} Uninstall The Ultimate Updater${CL}\n"
    echo -e "${RD}Really want to remove The Ultimate Updater?${CL}"
    read -p "Type [Y/y] for yes - anything else will exit: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm /usr/local/sbin/update
      rm -r $LOCAL_FILES
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
      echo -e "\n\n${BL} The Ultimate Updater has gone${CL}\n\
${BL} crontab file restored (old one backed up as crontab.bak)${CL}\n"
      exit 0
    fi
  else
    echo -e "${RD}The Ultimate Updater is not installed.${CL}\n"
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
    rm -rf $TEMP_FOLDER || true
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
