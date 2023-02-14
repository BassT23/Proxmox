#!/bin/bash

# This work only for Container NOT the Hosts itself
VERSION="1.1"

# Update PiHole if installed
hash pihole 2>/dev/null | {
  echo -e "*** Updating PiHole ***\n"
  /usr/local/bin/pihole -up
  echo
}

# Update Pterodactyl if installed
hash Pterodactyl 2>/dev/null | {
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
    hash nginx 2>/dev/null | {
      chown -R nginx:nginx /var/www/pterodactyl/*
    }
    # If using Apache on CentOS
    hash apache 2>/dev/null | {
      chown -R apache:apache /var/www/pterodactyl/*
    }
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
}

# Update Octoprint if installed
hash Octoprint 2>/dev/null | {
  echo -e "*** Updating Octoprint ***\n"
  ~/oprint/bin/pip install -U octoprint
  sudo service octoprint restart
  echo
}
