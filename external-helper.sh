#!/bin/sh

# Privileged helper for non-root External Linux updates.
# This file is installed root-owned on the External target by the explicit
# bootstrap flow. It accepts only fixed actions and never evaluates input.

set -eu

HELPER_VERSION=1
CONFIG_PATH=/etc/ultimate-updater/external.conf

usage() {
  printf 'Usage: %s version | status | config-read | config-write | update\n' "$0" >&2
}

validate_config() {
  [ -f "$1" ] && [ -r "$1" ] || return 44
  awk -F= '
    /^[[:space:]]*($|#)/ { next }
    {
      key=$1
      if (key !~ /^[A-Za-z_][A-Za-z0-9_]*$/ || seen[key]++) exit 1
      value=substr($0,index($0,"=")+1)
      if (length(value) > 513 || value ~ /[\r\n]/) exit 1
      if (key == "schema_version") { gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); if (value != "1" && value != "\"1\"") exit 1 }
      else if (key != "ONLY_UPDATE_CHECK" && key != "EXCLUDE_UPDATE_CHECK" && key != "ONLY" && key != "EXCLUDE") exit 1
    }
    END { exit(seen["schema_version"] ? 0 : 1) }
  ' "$1"
}

config_read() {
  validate_config "$CONFIG_PATH" || { printf 'external-helper: local config missing or invalid\n' >&2; return 44; }
  cat "$CONFIG_PATH"
}

config_write() {
  directory="" temporary="" backup="" stamp="" old=""
  [ "$(id -u)" -eq 0 ] || { printf 'external-helper: config write requires root\n' >&2; return 70; }
  directory=${CONFIG_PATH%/*}
  install -d -o root -g root -m 0755 "$directory"
  temporary=$(mktemp "$CONFIG_PATH.tmp.XXXXXX") || return 1
  trap 'rm -f "$temporary"' INT TERM EXIT
  cat > "$temporary" || return 1
  validate_config "$temporary" || { printf 'external-helper: rejected local config\n' >&2; return 44; }
  if [ -f "$CONFIG_PATH" ]; then
    stamp=$(date -u '+%Y%m%d-%H%M%S')
    backup="$CONFIG_PATH.bak.$stamp"
    [ ! -e "$backup" ] || backup="$CONFIG_PATH.bak.$stamp.$$"
    cp -p "$CONFIG_PATH" "$backup" || return 1
  fi
  chown root:root "$temporary"
  chmod 0644 "$temporary"
  mv -f "$temporary" "$CONFIG_PATH"
  trap - INT TERM EXIT
  find "$directory" -maxdepth 1 -type f -name 'external.conf.bak.*' -printf '%T@ %p\n' |
    sort -nr | awk 'NR > 5 { sub(/^[^ ]+ /, ""); print }' |
    while IFS= read -r old; do
      [ -z "$old" ] || rm -f -- "$old"
    done
  printf 'External config updated\n'
}

detect_os() {
  [ -r /etc/os-release ] || {
    printf 'external-helper: /etc/os-release is unavailable\n' >&2
    return 20
  }
  # shellcheck disable=SC1091
  . /etc/os-release
  UU_OS_ID=$(printf '%s %s' "${ID:-}" "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')
}

apt_status() {
  /usr/bin/apt-get -s upgrade
}

dnf_status() {
  set +e
  /usr/bin/dnf -q check-update
  status=$?
  set -e
  [ "$status" -eq 0 ] || [ "$status" -eq 100 ] || return "$status"
}

update_apt() {
  DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get update
  DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    dist-upgrade -y
  DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get --purge autoremove -y
  DEBIAN_FRONTEND=noninteractive /usr/bin/apt-get autoclean -y
}

update_dnf() {
  /usr/bin/dnf -y upgrade
}

action="${1:-}"
case "$action" in
  version)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    printf 'ultimate-updater-external %s\n' "$HELPER_VERSION"
    exit 0
    ;;
  status)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    detect_os
    case "$UU_OS_ID" in
      *debian*|*ubuntu*|*raspbian*) apt_status ;;
      *rocky*|*rhel*|*almalinux*|*fedora*) dnf_status ;;
      *) printf 'external-helper: unsupported operating system\n' >&2; exit 21 ;;
    esac
    exit 0
    ;;
  config-read)
    config_read
    exit $?
    ;;
  config-write)
    config_write
    exit $?
    ;;
  update)
    [ "$#" -eq 1 ] || { usage; exit 64; }
    [ "$(id -u)" -eq 0 ] || { printf 'external-helper: update requires root\n' >&2; exit 70; }
    detect_os
    case "$UU_OS_ID" in
      *debian*|*ubuntu*|*raspbian*) update_apt ;;
      *rocky*|*rhel*|*almalinux*|*fedora*) update_dnf ;;
      *) printf 'external-helper: unsupported operating system\n' >&2; exit 21 ;;
    esac
    ;;
  *)
    usage
    exit 64
    ;;
esac
