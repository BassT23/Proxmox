#!/bin/bash
#https://github.com/BassT23/Proxmox

#Variable / Function
VERSION="1.2.2"

#live
#SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/master"
#development
SERVER_URL="https://raw.githubusercontent.com/BassT23/Proxmox/development"
LOCAL_FILES="/root/Proxmox-Update-Scripts"

#Colors
BL='\033[36m'
RD='\033[01;31m'
GN='\033[1;92m'
CL='\033[m'

#Header
function HEADER_INFO {
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
function CHECK_ROOT {
  if [[ $EUID -ne 0 ]]; then
      echo -e >&2 "${RD}--- Please run this as root ---${CL}";
      exit 1
  fi
}

function USAGE {
    if [[ $SILENT != true ]]; then
        echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
        echo -e "[OPTIONS] Manages the Proxmox-Updater:"
        echo -e "======================================"
        echo -e "  -h --help            Show this help"
        echo -e "  -s --silent          Silent mode\n"
        echo -e "Commands:"
        echo -e "========="
        echo -e "  status               Check current installation status"
        echo -e "  install              Install Proxmox-Updater"
        echo -e "  uninstall            Uninstall Proxmox-Updater"
        echo -e "  update               Update Proxmox-Updater\n"
        echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>\n"
    fi
}

function isInstalled {
    if [ -f "/usr/local/bin/update" ]; then
        true
    else
        false
    fi
}

function STATUS {
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

function INSTALL {
    echo -e "\n${BL}[Info]${GN} Installing Proxmox-Updater${CL}\n"
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "${RD}Proxmox-Updater is already installed.${CL}"
      read -p "Should I update for you? Type [Y/y] or Enter for yes - enything else will exit " -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh) update
      else
        echo -e "\nBye\n"
        exit 0
      fi
    else
      mkdir -p /root/Proxmox-Update-Scripts/exit
      curl -s $SERVER_URL/update.sh > /usr/local/bin/update
      chmod 750 /usr/local/bin/update
      curl -s $SERVER_URL/exit/error.sh > $LOCAL_FILES/exit/error.sh
      curl -s $SERVER_URL/exit/passed.sh > $LOCAL_FILES/exit/passed.sh
      chmod +x $LOCAL_FILES/exit/*.*
      curl -s $SERVER_URL/update-extras.sh > $LOCAL_FILES/update-extras.sh
      echo -e "${BL}Finished. Run Proxmox-Updater with 'update'.${CL}\n"
    fi
}

function UPDATE {
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "\n${BL}[Info]${GN} Updating script ...${CL}\n"
      curl -s $SERVER_URL/update.sh >> /usr/local/bin/update
      # Check if files are different
      mkdir -p /root/Proxmox-Updater
      curl $SERVER_URL/exit/error.sh >> /root/Proxmox-Updater/error.sh
      curl $SERVER_URL/exit/passed.sh >> /root/Proxmox-Updater/passed.sh
      curl $SERVER_URL/update-extras.sh >> /root/Proxmox-Updater/update-extras.sh
      FILES="/root/Proxmox-Updater/*"
      for f in $FILES
      do
#        CHECK_DIFF
        echo "check $f ..."
      done
      rm -r /root/Proxmox-Updater
      echo -e "${GN}Proxmox-Updater updated successfully.${CL}\n"
    else
      echo -e "${RD}Proxmox-Updater is not installed.\n\n${GN}Would you like to install it?${CL}"
      read -p "Type [Y/y] or Enter for yes - enything else will exit " -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ || $REPLY = "" ]]; then
        bash <(curl -s $SERVER_URL/install.sh)
      else
        echo -e "\n\nBye\n"
        exit 0
      fi
    fi
}

function CHECK_DIFF {
  cmp --silent $old $f || echo "files are different"
  echo -e "The file $f\n \
 ==> Modified (by you or by a script) since installation.\n \
   What would you like to do about it ?  Your options are:\n \
    Y or y  : install the package maintainer's version\n \
    N or n  : keep your currently-installed version\n \
    S or s  : show the differences between the versions\n \
 The default action is to keep your current version.\n \
*** $f (Y/y/N/n/S/s) [default=N] ?\n \
 enything else will exit "
      read -p "" -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "install server version"
#        mv /root/Proxmox-Updater/error.sh >> $LOCAL_FILES/exit/error.sh
#        mv /root/Proxmox-Updater/passed.sh >> $LOCAL_FILES/exit/passed.sh
#        mv /root/Proxmox-Updater/update-extras.sh >> $LOCAL_FILES/update-extras.sh
      elif [[ $REPLY =~ ^[Nn]$ || $REPLY = "" ]]; then
        echo "keep your file"
      elif [[ $REPLY =~ ^[Ss]$ ]]; then
        echo "show differences"
      else
        echo -e "\n\nBye\n"
        exit 0
      fi
}

function UNINSTALL {
    echo -e "\n${BL}[Info]${GN} Uninstall Proxmox-Updater${CL}\n"
    if [ -f "/usr/local/bin/update" ]; then
      rm /usr/local/bin/update
      rm -r /root/Proxmox-Update-Scripts
      echo -e "${BL}Proxmox-Updater removed${CL}\n"
    else
      echo -e "${RD}Proxmox-Updater is not installed.${CL}\n"
    fi
}

#Error/Exit
set -e
function EXIT {
  EXIT_CODE=$?
  # Install Finish
  if [[ $EXIT_CODE != "0" ]]; then
    echo -e "${RD}Error during install --- Exit Code: $EXIT_CODE${CL}\n"
  fi
}

# Exit Code
trap EXIT EXIT

#Install
HEADER_INFO
parse_cli()
{
  while test $# -gt -0
  do
    _key="$1"
    case "$_key" in
      -h|--help)
        USAGE
        exit 0
        ;;
      -s|--silent)
        SILENT=true
        ;;
      status)
        STATUS
        exit 0
        ;;
      install)
        COMMAND=true
        INSTALL
        exit 0
        ;;
      uninstall)
        COMMAND=true
        UNINSTALL
        exit 0
        ;;
      update)
        COMMAND=true
        UPDATE
        exit 0
        ;;
      *)
        echo -e "${RD}Error: Got an unexpected argument \"$_key\"${CL}\n";
        USAGE;
        exit 1;
        ;;
    esac
    shift
  done
}
parse_cli "$@"

# Run without commands
if [[ $COMMAND != true ]]; then
  INSTALL
fi
