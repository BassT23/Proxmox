#!/bin/sh

# Explicit administrator bootstrap for an External target. Run this on the
# External host as root (normally via sudo) after copying this script and
# external-helper.sh there. It never handles passwords or SSH keys.

set -eu

HELPER_PATH=/usr/local/sbin/ultimate-updater-external
SUDOERS_PATH=/etc/sudoers.d/ultimate-updater
source_helper="${1:-}"
target_user="${2:-${SUDO_USER:-}}"
temporary_helper=""
temporary_sudoers=""
backup_helper=""
backup_sudoers=""
had_helper=false
had_sudoers=false

cleanup() {
  [ -z "$temporary_helper" ] || rm -f "$temporary_helper"
  [ -z "$temporary_sudoers" ] || rm -f "$temporary_sudoers"
  [ -z "$backup_helper" ] || rm -f "$backup_helper"
  [ -z "$backup_sudoers" ] || rm -f "$backup_sudoers"
}
trap cleanup EXIT HUP INT TERM

[ "$(id -u)" -eq 0 ] || { printf 'external-bootstrap: run as root\n' >&2; exit 70; }
if [ -z "$source_helper" ] || [ ! -f "$source_helper" ] || [ ! -r "$source_helper" ]; then
  printf 'external-bootstrap: readable helper path required\n' >&2
  exit 64
fi
printf '%s\n' "$target_user" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]*$' || {
  printf 'external-bootstrap: valid target user required\n' >&2
  exit 64
}

temporary_helper=$(mktemp /tmp/ultimate-updater-helper.XXXXXX)
temporary_sudoers=$(mktemp /tmp/ultimate-updater-sudoers.XXXXXX)
if [ -e "$HELPER_PATH" ]; then
  backup_helper=$(mktemp /tmp/ultimate-updater-helper-backup.XXXXXX)
  cp -p "$HELPER_PATH" "$backup_helper"
  had_helper=true
fi
if [ -e "$SUDOERS_PATH" ]; then
  backup_sudoers=$(mktemp /tmp/ultimate-updater-sudoers-backup.XXXXXX)
  cp -p "$SUDOERS_PATH" "$backup_sudoers"
  had_sudoers=true
fi
install -o root -g root -m 0755 "$source_helper" "$temporary_helper"
"$temporary_helper" version >/dev/null
mv -f "$temporary_helper" "$HELPER_PATH"
temporary_helper=""

printf '%s ALL=(root) NOPASSWD: %s update\n' "$target_user" "$HELPER_PATH" > "$temporary_sudoers"
chmod 0440 "$temporary_sudoers"
visudo -cf "$temporary_sudoers" >/dev/null
install -o root -g root -m 0440 "$temporary_sudoers" "$SUDOERS_PATH"
temporary_sudoers=""
if ! visudo -cf /etc/sudoers >/dev/null; then
  if [ "$had_helper" = true ]; then mv -f "$backup_helper" "$HELPER_PATH"; backup_helper=""; else rm -f "$HELPER_PATH"; fi
  if [ "$had_sudoers" = true ]; then mv -f "$backup_sudoers" "$SUDOERS_PATH"; backup_sudoers=""; else rm -f "$SUDOERS_PATH"; fi
  printf 'external-bootstrap: sudoers validation failed; changes rolled back\n' >&2
  exit 1
fi
rm -f "$backup_helper" "$backup_sudoers"
backup_helper=""
backup_sudoers=""
printf 'External helper installed: %s\n' "$HELPER_PATH"
printf 'Sudo rule installed: %s\n' "$SUDOERS_PATH"
