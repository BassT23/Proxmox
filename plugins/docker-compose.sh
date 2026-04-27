#!/bin/bash

#####################
# Plugin: Docker    #
#####################
# Updates all Docker Compose projects found under COMPOSE_PATH.
#
# WARNING: After updating images, this plugin runs a full Docker cleanup:
#   docker system prune -a -f --volumes
# This permanently removes ALL unused images, containers, networks, and
# volumes — including those unrelated to the updated projects. Only enable
# DOCKER_PRUNE if you understand and accept this behaviour.

CONFIG_FILE="${CONFIG_FILE:-/etc/ultimate-updater/update.conf}"
DOCKER_COMPOSE=$(awk -F'"' '/^DOCKER_COMPOSE=/ {print $2}' "${CONFIG_FILE}")
DOCKER_PRUNE=$(awk -F'"' '/^DOCKER_PRUNE=/ {print $2}' "${CONFIG_FILE}")
COMPOSE_PATH=$(awk -F'"' '/^COMPOSE_PATH=/ {print $2}' "${CONFIG_FILE}")
COMPOSE_PATH="${COMPOSE_PATH:-/home}"

[[ "${DOCKER_COMPOSE}" == true ]] || exit 0

_HAS_V1=false
_HAS_V2=false
[[ -f /usr/local/bin/docker-compose ]] && _HAS_V1=true
docker compose version &>/dev/null && _HAS_V2=true

[[ "${_HAS_V1}" == true || "${_HAS_V2}" == true ]] || exit 0

_DIRLIST=()
for _pattern in "docker-compose.y*ml" "compose.y*ml"; do
  while IFS= read -r _dir; do
    _DIRLIST+=("${_dir}")
  done < <(find "${COMPOSE_PATH}" -name "${_pattern}" -exec dirname {} \; 2> >(grep -v 'Permission denied' >&2))
done

if [[ ${#_DIRLIST[@]} -eq 0 ]]; then
  echo "No Docker Compose projects found under ${COMPOSE_PATH}"
  exit 0
fi

_docker_prune() {
  if [[ "${DOCKER_PRUNE:-false}" == true ]]; then
    echo ""
    echo "--- Docker cleanup ---"
    docker container prune -f
    docker image prune -f
    docker system prune -a -f --volumes
  fi
}

if [[ "${_HAS_V2}" == true ]]; then
  echo ""
  echo "--- Updating Docker Compose projects ---"
  for _dir in "${_DIRLIST[@]}"; do
    echo "Updating ${_dir}..."
    pushd "${_dir}" >/dev/null || continue
    docker compose pull && docker compose up -d
    popd >/dev/null || true
  done
  echo "All projects updated."
  _docker_prune
elif [[ "${_HAS_V1}" == true ]]; then
  echo ""
  echo "--- Updating Docker Compose v1 projects ---"
  for _dir in "${_DIRLIST[@]}"; do
    echo "Updating ${_dir}..."
    pushd "${_dir}" >/dev/null || continue
    /usr/local/bin/docker-compose pull
    /usr/local/bin/docker-compose up --force-recreate --build -d
    popd >/dev/null || true
  done
  echo "All projects updated."
  _docker_prune
fi
