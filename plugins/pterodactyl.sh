#!/bin/bash

########################
# Plugin: Pterodactyl  #
########################
# Updates Pterodactyl Panel and Wings.

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2}' "${CONFIG_FILE}")

[[ "${PTERODACTYL}" == true ]] || exit 0
[[ -d /var/www/pterodactyl ]] || exit 0

echo ""
echo "--- Updating Pterodactyl Panel ---"

cd /var/www/pterodactyl || exit 1
php artisan down
curl -L https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz | tar -xzv
chmod -R 755 storage/* bootstrap/cache
composer install --no-dev --optimize-autoloader
php artisan view:clear
php artisan config:clear
php artisan migrate --seed --force

if id -u nginx >/dev/null 2>&1; then
  chown -R nginx:nginx /var/www/pterodactyl/*
elif id -u apache >/dev/null 2>&1; then
  chown -R apache:apache /var/www/pterodactyl/*
else
  chown -R www-data:www-data /var/www/pterodactyl/*
fi

php artisan queue:restart
php artisan up

echo "--- Updating Wings ---"
systemctl stop wings
_arch=$([[ "$(uname -m)" == x86_64 ]] && echo amd64 || echo arm64)
curl -L -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${_arch}"
chmod u+x /usr/local/bin/wings
systemctl restart wings
