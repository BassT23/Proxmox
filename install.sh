#!/bin/bash

#bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) install

#Variable / Function
VERSION=1.1

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
function CHECK_ROOT() {
  if [[ $RICM != "1" && $EUID -ne 0 ]]; then
      echo -e >&2 "${RD}--- Please run this as root ---${CL}";
      exit 1
  fi
}

function USAGE {
    if [ "$_silent" = false ]; then
        echo -e "Usage: $0 [OPTIONS...] {COMMAND}\n"
        echo -e "Manages the Proxmox-Updater."
        echo -e "  -h --help            Show this help"
        echo -e "  -s --silent          Silent mode\n"
        echo -e "Commands:"
        echo -e "  status               Check current installation status"
        echo -e "  install              Install Proxmox-Updater"
        echo -e "  uninstall            Uninstall Proxmox-Updater"
        echo -e "  update               Update Proxmox-Updater\n"
    #    echo -e "  utility-update       Update this utility\n" (to be implemented)
        echo -e "Exit status:"
        echo -e "  0                    OK"
        echo -e "  1                    Failure"
        echo -e "  2                    Already installed, OR not installed (when using install/uninstall commands)\n"
        echo -e "Report issues at: <https://github.com/BassT23/Proxmox/issues>"
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
    if [ "$_silent" = false ]; then
        echo -e "Proxmox-Updater"
        if isInstalled; then
            echo -e "Status: ${GN}present${CL}\n"
        else
            echo -e "Status: ${RD}not present${CL}\n"
        fi
    fi
    if isInstalled; then exit 0; else exit 1; fi
}

function INSTALL(){
    echo -e "\n${BL}[Info]${GN} Installing Proxmox-Updater${CL}\n"
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "${RD}Proxmox-Updater is already installed.${CL}"
      read -p "Should I update for you? Type [Y/y] for yes - enything else will exit " -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
      else
        echo -e "\nBye\n"
        exit 0
      fi
    else
      mkdir -p /root/Proxmox-Update-Scripts/exit
      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/update > /usr/local/bin/update
      chmod 750 /usr/local/bin/update
      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/error.sh > /root/Proxmox-Update-Scripts/exit/error.sh
      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/passed.sh > /root/Proxmox-Update-Scripts/exit/passed.sh
      chmod +x /root/Proxmox-Update-Scripts/exit/*.*
      echo -e "${BL}Finished. Run Proxmox-Updater with 'update'.${CL}\n"
    fi
}

function UPDATE(){
    if [ -f "/usr/local/bin/update" ]; then
      echo -e "\n${BL}[Info]${GN} Updating script ...${CL}\n"
      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/update > /usr/local/bin/update
      # Check if files are modified by user
#      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/error.sh > /root/Proxmox-Update-Scripts/exit/error.sh
#      curl -s https://raw.githubusercontent.com/BassT23/Proxmox/main/exit/passed.sh > /root/Proxmox-Update-Scripts/exit/passed.sh
      echo -e "${GN}Proxmox-Updater updated successfully.${CL}\n"
    else
      echo -e "${RD}Proxmox-Updater is not installed.\n\n${GN}Would you like to install it?${CL}"
      read -p "Type [Y/y] for yes - enything else will exit " -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) install
      else
        echo -e "\n\nBye\n"
        exit 0
      fi
    fi
}

function UNINSTALL(){
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
function EXIT() {
  EXIT_CODE=$?
  # Install Finish
  if [[ $EXIT_CODE != "0" ]]; then
    echo -e "${RD}Error during install --- Exit Code: $EXIT_CODE${CL}\n"
  fi
}

# Exit Code
trap EXIT EXIT

_silent=false
_command=false

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
                _silent=true
                ;;
            status)
                if [ "$_command" = false ]; then
                    _command=true
                    STATUS
                fi
                ;;
            install)
                if [ "$_command" = false ]; then
                    _command=true
                    INSTALL
                    exit 0
                fi
                ;;
            uninstall)
                if [ "$_command" = false ]; then
                    _command=true
                    UNINSTALL
                    exit 0
                fi
                ;;
            update)
                if [ "$_command" = false ]; then
                    _command=true
#                    _noexit=true
                    UPDATE
                    exit 0
                fi
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
