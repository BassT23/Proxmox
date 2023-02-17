#!/bin/bash

# This work only for Container NOT the Hosts itself
VERSION="1.6"

#To disable extra update change "true" to "false"
PIHOLE=true
IOBROKER=true
PTERODACTYL=true
OCTOPRINT=true
DOCKER_IMAGES=true   # Docker-Compose

# Update PiHole if installed
if [[ -f "/usr/local/bin/pihole" && $PIHOLE == true ]]; then
  echo -e "*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
  echo
fi

# Update ioBroker if installed
if [[ -d "/opt/iobroker" && $IOBROKER == true ]]; then
  echo -e "*** Updating ioBroker ***\n"
  echo "*** Stop ioBroker ***" && iob stop
  echo
  echo "*** Update/Upgrade ioBroker ***" && iob update && iob upgrade -y && iob upgrade self -y
  echo
  echo "*** Start ioBroker ***" && iob start
  echo
fi

# Update Pterodactyl if installed
if [[ -d "/var/www/pterodactyl" && $PTERODACTYL == true ]]; then
  echo -e "*** Updating Pterodactyl ***\n"
  cd /var/www/pterodactyl
  php artisan down
  curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv
  chmod -R 755 storage/* bootstrap/cache
  composer install --no-dev --optimize-autoloader
  php artisan view:clear
  php artisan config:clear
  php artisan migrate --seed --force
  os=$(awk '/^ostype/' temp | cut -d' ' -f2)
  if [[ $os == centos ]]; then
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
  echo
fi

# Update Octoprint if installed
if [[ -d "/root/OctoPrint" && $OCTOPRINT == true ]]; then
  echo -e "*** Updating Octoprint ***\n"
  ~/oprint/bin/pip install -U octoprint
  sudo service octoprint restart
  echo
fi

# Update Docker Container-Compose
if [[ -f "/usr/local/bin/docker-compose" && $DOCKER_IMAGES == true ]]; then
  # Update
  docker-compose up --force-recreate --build -d
  # Cleaning    (disabled during beta)
#  docker container prune -f
#  docker system prune -a -f
#  docker image prune -f
#  docker system prune --volumes -f
fi
