#!/bin/bash

#################
# Update-Extras #
#################

# shellcheck disable=SC2034,SC2086

VERSION="3.1"

set -Eeo pipefail

EXTRA_ERROR() {
  local rc=$?
  local line_number="$1"
  local failed_command="$2"

  trap - ERR
  printf 'ERROR: Extra update failed at line %s while running: %s (exit code: %s)\n' \
    "$line_number" "$failed_command" "$rc" >&2
  exit "$rc"
}
trap 'EXTRA_ERROR "$LINENO" "$BASH_COMMAND"' ERR

# Variables
LOCAL_FILES="${LOCAL_FILES:-/etc/ultimate-updater}"
CONFIG_FILE="${UU_UPDATE_CONFIG_FILE:-$LOCAL_FILES/update.conf}"
PIHOLE=$(awk -F'"' '/^PIHOLE=/ {print $2}' $CONFIG_FILE)
IOBROKER=$(awk -F'"' '/^IOBROKER=/ {print $2}' $CONFIG_FILE)
PTERODACTYL=$(awk -F'"' '/^PTERODACTYL=/ {print $2}' $CONFIG_FILE)
OCTOPRINT=$(awk -F'"' '/^OCTOPRINT=/ {print $2}' $CONFIG_FILE)
DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2}' $CONFIG_FILE)
COMPOSE_PATH=$(awk -F'"' '/^COMPOSE_PATH=/ {print $2}' $CONFIG_FILE)
INCLUDE_HELPER_SCRIPTS=$(awk -F'"' '/^INCLUDE_HELPER_SCRIPTS=/ {print $2}' $CONFIG_FILE)
IN_HEADLESS_MODE=$(awk -F'"' '/^IN_HEADLESS_MODE=/ {print $2}' $CONFIG_FILE)
COMMUNITY_UPDATE_COMMAND="${UU_COMMUNITY_UPDATE_COMMAND:-update}"

if [[ "$IN_HEADLESS_MODE" == true ]]; then
  export DEBIAN_FRONTEND=noninteractive
fi

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
  COMPOSEFILES=("docker-compose.y*ml" "compose.y*ml")
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
COMMUNITY_UPDATE_PATH=$(command -v "$COMMUNITY_UPDATE_COMMAND" 2>/dev/null || true)
if [[ -n "$COMMUNITY_UPDATE_PATH" ]] && grep -q "community-scripts" "$COMMUNITY_UPDATE_PATH" 2>/dev/null && [[ $INCLUDE_HELPER_SCRIPTS == true ]]; then
  echo -e "\n*** Updating Community-Scripts ***"
  COMMUNITY_UPDATE_LOG=$(mktemp)
  # Community helpers are automated update tools.  Do not let a controlling
  # terminal become their stdin: nested terminal ioctls such as `stty sane`
  # must not be able to stop the helper's background process group with
  # SIGTTOU.  stdout/stderr remain attached to tee for live output.
  trap - ERR
  set +e
  env PHS_SILENT=1 "$COMMUNITY_UPDATE_COMMAND" </dev/null 2>&1 | tee "$COMMUNITY_UPDATE_LOG"
  COMMUNITY_PIPE_STATUS=("${PIPESTATUS[@]}")
  set -e
  trap 'EXTRA_ERROR "$LINENO" "$BASH_COMMAND"' ERR

  COMMUNITY_UPDATE_EXIT=${COMMUNITY_PIPE_STATUS[0]:-1}
  COMMUNITY_TEE_EXIT=${COMMUNITY_PIPE_STATUS[1]:-0}
  if [[ $COMMUNITY_UPDATE_EXIT -ne 0 ]]; then
    echo -e "⚠️ Community-Scripts update failed with exit code $COMMUNITY_UPDATE_EXIT" >&2
    rm -f "$COMMUNITY_UPDATE_LOG"
    exit "$COMMUNITY_UPDATE_EXIT"
  elif [[ $COMMUNITY_TEE_EXIT -ne 0 ]]; then
    echo -e "⚠️ Community-Scripts output capture failed with exit code $COMMUNITY_TEE_EXIT" >&2
    rm -f "$COMMUNITY_UPDATE_LOG"
    exit "$COMMUNITY_TEE_EXIT"
  fi

  echo -e "✅ Update process completed\n"
  rm -f "$COMMUNITY_UPDATE_LOG"
fi
