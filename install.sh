#!/bin/bash

#Variable / Function
LOG_FILE=/var/log/update-$HOSTNAME.log    # <- change location for logfile if you want
VERSION=3.2

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
           *** Version:  $VERSION  *** \n \
           *** Mode: $MODE ***"
  if [[ $HEADLESS == "1" ]]; then
    echo -e "            ***    Headless    ***"
  else
    if [[ $UPDATE != "1" ]]; then
    echo -e "            ***  Interactive   ***"
    fi
  fi
  CHECK_ROOT
}

#Update Options
while getopts 123xhu opt 2>/dev/null
do
  case $opt in
    1) CLUSTER_MODE=1;;
    2) HOST_MODE=1;;
    3) HEADLESS=1;;
    x) RICM=1;; # Run In Cluster Mode
    u) UPDATE=1;;
    h) echo -e "\nOptions: \
                \n======== \
                \n-1   Cluster Mode (Automatic - No need to set) \
                \n-2   Host Mode \
                \n-3   Headless \
                \n-u   Update Proxmox-Updater\n"
       exit 1;;
    ?) echo -e "Wrong option! (-h for Help)"
       exit 1
  esac
done

#Check root
function CHECK_ROOT() {
  if [[ $RICM != "1" && $EUID -ne 0 ]]; then
      echo -e "\n ${RD}--- Please run this as root ---${CL}\n"
      exit 0
  fi
}

#Check Cluster Mode
if [ -f "/etc/corosync/corosync.conf" ]; then
  HOSTS=$(awk '/ring0_addr/{print $2}' "/etc/corosync/corosync.conf")
fi

#Host Update
function UPDATE_HOST() {
  HOST=$1
  echo -e "\n${BL}[Info]${GN} Updating${CL} : ${GN}$HOST${CL}"
  if [[ $HEADLESS == "1" ]]; then
    ssh "$HOST" 'bash -s' < "$0" -- -23x
  else
    ssh "$HOST" 'bash -s' < "$0" -- -2x
  fi
}

#Host Update Start
function HOST_UPDATE_START() {
  for HOST in $HOSTS; do
    UPDATE_HOST "$HOST"
  done
}

#Container Update
function UPDATE_CONTAINER() {
  CONTAINER=$1
  NAME=$(pct exec "$CONTAINER" hostname)
  echo -e "${BL}[Info]${GN} Updating LXC ${BL}$CONTAINER${CL} : ${GN}$NAME${CL}\n"
  pct config "$CONTAINER" > temp
  os=$(awk '/^ostype/' temp | cut -d' ' -f2)
  case "$os" in
    "ubuntu" | "debian" | "devuan")
      pct exec "$CONTAINER" -- bash -c "echo -e --- APT UPDATE --- && apt-get update && echo"
      if [[ $HEADLESS == "1" ]]; then
        pct exec "$CONTAINER" -- bash -c "echo -e --- APT UPGRADE HEADLESS --- && \
                                          DEBIAN_FRONTEND=noninteractive apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y && \
                                          DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y && echo"
      else
        pct exec "$CONTAINER" -- bash -c "echo -e --- APT UPGRADE --- && \
                                          apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y && \
                                          apt-get full-upgrade -y && echo"
      fi
      pct exec "$CONTAINER" -- bash -c "echo -e --- APT CLEANING --- && \
                                          apt-get --purge autoremove -y && echo";;
    "fedora")
      pct exec "$CONTAINER" -- bash -c "echo -e --- DNF UPDATE --- && dnf -y update && echo"
      pct exec "$CONTAINER" -- bash -c "echo -e --- DNF UPGRATE --- && dnf -y upgrade && echo"
      pct exec "$CONTAINER" -- bash -c "echo -e --- DNF CLEANING --- && dnf -y --purge autoremove && echo";;
    "archlinux")
      pct exec "$CONTAINER" -- bash -c "echo -e --- PACMAN UPDATE --- && pacman -Syyu --noconfirm && echo";;
    "alpine")
      pct exec "$CONTAINER" -- ash -c "echo -e --- APK UPDATE --- && apk -U upgrade && echo";;
    *)
      pct exec "$CONTAINER" -- bash -c "echo -e --- YUM UPDATE --- && yum -y update && echo";;
  esac
}

#Container Update Start
function CONTAINER_UPDATE_START() {
  # Get the list of containers
  CONTAINERS=$(pct list | tail -n +2 | cut -f1 -d' ')
  # Loop through the containers
  for CONTAINER in $CONTAINERS; do
    status=$(pct status "$CONTAINER")
    if [[ $status == "status: stopped" ]]; then
      echo -e "${BL}[Info]${GN} Starting${BL} $CONTAINER ${CL}\n"
      # Start the container
      pct start "$CONTAINER"
      echo -e "${BL}[Info]${GN} Waiting For${BL} $CONTAINER${CL}${GN} To Start ${CL}\n"
      sleep 5
      UPDATE_CONTAINER "$CONTAINER"
      echo -e "${BL}[Info]${GN} Shutting down${BL} $CONTAINER ${CL}\n"
      # Stop the container
      pct shutdown "$CONTAINER" &
    elif [[ $status == "status: running" ]]; then
      UPDATE_CONTAINER "$CONTAINER"
    fi
  done
  rm -rf temp
}

function UPDATE_HOST_ITSELF() {
  echo -e "\n--- APT UPDATE ---" && apt-get update
  if [[ $HEADLESS == "1" ]]; then
    echo -e "\n--- APT UPGRADE HEADLESS ---" && \
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  else
    echo -e "\n--- APT UPGRADE ---" && \
            apt-get upgrade -y
  fi
  echo -e "\n--- APT CLEANING ---" && \
          apt-get --purge autoremove -y && echo
}

# Logging
if [[ $RICM != "1" ]]; then
  touch "$LOG_FILE"
  exec &> >(tee "$LOG_FILE")
fi
function CLEAN_LOGFILE() {
  if [[ $RICM != "1" ]]; then
    tail -n +2 "$LOG_FILE" > tmp.log && mv tmp.log "$LOG_FILE"
    cat $LOG_FILE | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,3})*)?[mGK]//g" | tee "$LOG_FILE"
    chmod 640 "$LOG_FILE"
    if [ -f "./tmp.log" ]; then
      rm ./tmp.log
    fi
  fi
}

# Error/Exit
set -e
function EXIT() {
  EXIT_CODE=$?
  # Update Finish
  if [[ $EXIT_CODE = "0" ]]; then
    echo -e "${GN}Finished, All Containers Updated.${CL}\n"
    /root/Proxmox-Update-Scripts/exit/passed.sh
  # Update Error
  else
    echo -e "${RD}Error during Update --- Exit Code: $EXIT_CODE${CL}\n"
    /root/Proxmox-Update-Scripts/exit/error.sh
  fi
  CLEAN_LOGFILE
}

# Exit Code
if [[ $RICM != "1" && $UPDATE != "1" ]]; then
  trap EXIT EXIT
fi

#Update Proxmox-Updater
if [[ $UPDATE == "1" ]]; then
  MODE=" Update "
  HEADER_INFO
  echo -e "\n${BL}[Info]${GN} Updating script ...${CL}\n"
  bash <(curl -s https://raw.githubusercontent.com/BassT23/Proxmox/master/install.sh) update
  exit 0
fi

#Update Start
export TERM=xterm-256color
if [[ -f /etc/corosync/corosync.conf && $HOST_MODE != "1" ]]; then
  MODE=" Cluster"
  HEADER_INFO
  HOST_UPDATE_START
  exit 0
else
  if [[ $RICM != "1" ]]; then
    MODE="  Host  "
    HEADER_INFO
  fi
    if [[ $RICM != "1" ]]; then
      echo -e "\n${BL}[Info]${GN} Updating${CL} : ${GN}$HOSTNAME${CL}"
    fi
  UPDATE_HOST_ITSELF
  CONTAINER_UPDATE_START
  exit 0
fi
