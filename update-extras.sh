#!/bin/bash

#################
# Update-Extras #
#################

VERSION="1.8.3"

# Variables
CONFIG_FILE="/root/Proxmox-Updater/update.conf"
PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2}' $CONFIG_FILE)
IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2}' $CONFIG_FILE)
PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2}' $CONFIG_FILE)
OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2}' $CONFIG_FILE)
DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2}' $CONFIG_FILE)

# PiHole
if [[ -f "/usr/local/bin/pihole" && $PIHOLE == true ]]; then
  echo -e "\n*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
fi

# ioBroker
if [[ -d "/opt/iobroker" && $IOBROKER == true ]]; then
  echo -e "\n*** Updating ioBroker ***\n"
  echo "*** Stop ioBroker ***" && iob stop && echo
  echo "*** Update/Upgrade ioBroker ***" && iob update && iob upgrade -y && iob upgrade self -y && echo
  echo "*** Start ioBroker ***" && iob start && echo
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

# Docker-Compose
if [[ -d "/etc/docker" && $DOCKER_COMPOSE == true ]]; then
  if COMPOSE=$(find /home -name "docker-compose.yaml" >/dev/null 2>&1 | rev | cut -c 20- | rev | tail -n 1); then
    :
  elif COMPOSE=$(find /home -name "docker-compose.yml" >/dev/null 2>&1 | rev | cut -c 20- | rev | tail -n 1); then
    :
  fi
  cd "$COMPOSE" || exit
  echo -e "\n*** Updating Docker-Compose ***"
  # Get the containers from first argument, else get all containers
  CONTAINER_LIST="${1:-$(docker ps -q)}"
  for CONTAINER in ${CONTAINER_LIST}; do
    # Get requirements
    CONTAINER_IMAGE=$(docker inspect --format "{{.Config.Image}}" --type container "${CONTAINER}")
    RUNNING_IMAGE=$(docker inspect --format "{{.Image}}" --type container "${CONTAINER}")
    NAME=$(docker inspect --format "{{.Name}}" --type container "${CONTAINER}" | cut -c 2-)
    # Pull in latest version of the container and get the hash
    docker pull "${CONTAINER_IMAGE}" 2> /dev/null
    LATEST_IMAGE=$(docker inspect --format "{{.Id}}" --type image "${CONTAINER_IMAGE}")
    # Restart the container if the image is different by name
    if [[ ${RUNNING_IMAGE} != "${LATEST_IMAGE}" ]]; then
      echo "Updating ${CONTAINER} image ${CONTAINER_IMAGE}"
      docker compose up -d --no-deps --build "$NAME"
    fi
  done
  # Cleaning
  echo -e "\n*** Cleaning ***"
  docker container prune -f
  docker system prune -a -f
  docker image prune -f
  docker system prune --volumes -f
fi
