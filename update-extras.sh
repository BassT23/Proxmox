#!/bin/bash

#################
# Update-Extras #
#################

# shellcheck disable=SC1017
# shellcheck disable=SC2034

VERSION="1.9.3"

# Variables
CONFIG_FILE="/etc/ultimate-updater/update.conf"
PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2}' $CONFIG_FILE)
IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2}' $CONFIG_FILE)
PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2}' $CONFIG_FILE)
OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2}' $CONFIG_FILE)
DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2}' $CONFIG_FILE)
COMPOSE_PATH=$(awk -F'"' '/^COMPOSE_PATH=/ {print $2}' $CONFIG_FILE)
INCLUDE_HELPER_SCRIPTS=$(awk -F'"' '/^INCLUDE_HELPER_SCRIPTS=/ {print $2}' $CONFIG_FILE)

# PiHole
if [[ -f "/usr/local/bin/pihole" && $PIHOLE == true ]]; then
  echo -e "\n*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
fi

# ioBroker
if [[ -d "/opt/iobroker" && $IOBROKER == true ]]; then
  echo -e "\n*** Updating ioBroker ***\n"
  echo "*** Stop ioBroker ***" &&  sudo -u iobroker bash -c "iob stop" && echo
  echo "*** Update/Upgrade ioBroker ***" && sudo -u iobroker bash -c "iob update" && sudo -u iobroker bash -c "iob upgrade -y" && sudo -u iobroker bash -c "iob upgrade self -y" && echo
  echo "*** Start ioBroker ***" && sudo -u iobroker bash -c "iob start" && echo
  if [[ -d "/opt/iobroker/iobroker-data/radar2.admin" ]]; then
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which arp-scan)')"
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which node)')"
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which arp)')"
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which hcitool)')"
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which hciconfig)')"
    setcap cap_net_admin,cap_net_raw,cap_net_bind_service=+eip "$(eval readlink -f '$(which l2ping)')"
  fi
fi

# Pterodactyl
if [[ -d "/var/www/pterodactyl" && $PTERODACTYL == true ]]; then
  echo -e "\n*** Updating Pterodactyl ***\n"
  cd /var/www/pterodactyl || exit
  php artisan down
  curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv
  chmod -R 755 storage/* bootstrap/cache
  composer install --no-dev --optimize-autoloader
  php artisan view:clear
  php artisan config:clear
  php artisan migrate --seed --force
  os=$(hostnamectl | grep System)
  if [[ $os =~ CentOS ]]; then
    # If using NGINX on CentOS:
    if id -u "nginx" >/dev/null 2>&1; then
      chown -R nginx:nginx /var/www/pterodactyl/*
    # If using Apache on CentOS
    elif id -u "apache" >/dev/null 2>&1; then
      chown -R apache:apache /var/www/pterodactyl/*
    fi
  else
    # If using NGINX or Apache (not on CentOS):
    chown -R www-data:www-data /var/www/pterodactyl/*
  fi
  php artisan queue:restart
  php artisan up
  #Upgrading Wings
  systemctl stop wings
  curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
  chmod u+x /usr/local/bin/wings
  systemctl restart wings
fi

# Octoprint
if [[ -d "/root/OctoPrint" && $OCTOPRINT == true ]]; then
  echo -e "\n*** Updating Octoprint ***\n"
  # find octoprint
  OPRINT=$(find /home -name "oprint")
  "$OPRINT"/bin/pip install -U --ignore-installed octoprint
  sudo service octoprint restart
fi

# Docker Compose detection
if [[ -f /usr/local/bin/docker-compose ]]; then DOCKER_COMPOSE_V1=true; fi
if docker compose version &>/dev/null; then DOCKER_COMPOSE_V2=true; fi

# Docker-Compose run
if [[ $DOCKER_COMPOSE_V1 == true || $DOCKER_COMPOSE_V2 == true ]] && [[ $DOCKER_COMPOSE == true ]]; then
  # Cleaning
  DOCKER_EXIT () {
    echo -e "\n*** Cleaning ***"
    docker container prune -f
    docker system prune -a -f
    docker image prune -f
    docker system prune --volumes -f
  }
  COMPOSEFILES=("docker-compose.yaml" "docker-compose.yml" "compose.yaml" "compose.yml")
  DIRLIST=()
  for COMPOSEFILE in "${COMPOSEFILES[@]}"; do
    while IFS= read -r line; do
      DIRLIST+=("$line")
    done < <(find "$COMPOSE_PATH" -name "$COMPOSEFILE" -exec dirname {} \; 2> >(grep -v 'Permission denied'))
  done
  # Docker-Compose v1
  if [[ $DOCKER_COMPOSE_V1 == true && ${#DIRLIST[@]} -gt 0 ]]; then
    echo -e "\n*** Updating Docker-Compose v1 (oldstable) ***\n"
    for dir in "${DIRLIST[@]}"; do
      echo "Updating $dir..."
      pushd "$dir" > /dev/null || return
      /usr/local/bin/docker-compose pull
      /usr/local/bin/docker-compose up --force-recreate --build -d
      /usr/local/bin/docker-compose restart
      popd > /dev/null || return
    done
    echo "All projects have been updated."
    DOCKER_EXIT
  fi
  # Docker-Compose v2
  if [[ $DOCKER_COMPOSE_V2 == true && ${#DIRLIST[@]} -gt 0 ]]; then
    echo -e "\n*** Updating Docker Compose ***"
    for dir in "${DIRLIST[@]}"; do
      echo "Updating $dir..."
      pushd "$dir" > /dev/null || return
      docker compose pull && docker compose up -d
      popd > /dev/null || return
    done
    echo "All projects have been updated."
    DOCKER_EXIT
  fi
fi

# Community / Helper Scripts
if grep -q "community-scripts" /usr/bin/update 2>/dev/null && [[ $INCLUDE_HELPER_SCRIPTS == true ]];then
  stdbuf -oL -eL expect <<EOF | grep -v "whiptail"
set timeout 3
spawn update
expect "Choose an option:"
send "2\r"
expect "<Ok>"
send "\r"
expect eof
EOF
  echo "✅ Update process completed"
fi