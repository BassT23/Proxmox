#!/bin/sh

# Privileged helper for non-root External Linux updates.
# This file is installed root-owned on the External target by the explicit
# bootstrap flow. It accepts only fixed actions and never evaluates input.

set -eu

HELPER_VERSION=1

usage() {
  printf 'Usage: %s version | status | update\n' "$0" >&2
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
