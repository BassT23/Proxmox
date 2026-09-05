#!/bin/sh

# Explicit administrator bootstrap for an External target. Run this on the
# External host as root (normally via sudo) after copying this script and
# external-helper.sh there. It never handles passwords or SSH keys.

set -eu

HELPER_PATH=/usr/local/sbin/ultimate-updater-external
SUDOERS_PATH=/etc/sudoers.d/ultimate-updater
CONFIG_PATH=/etc/ultimate-updater/external.conf
source_helper="${1:-}"
target_user="${2:-${SUDO_USER:-}}"
source_config="${3:-}"
temporary_helper=""
temporary_sudoers=""
temporary_config=""
backup_helper=""
backup_sudoers=""
had_helper=false
had_sudoers=false

cleanup() {
  [ -z "$temporary_helper" ] || rm -f "$temporary_helper"
  [ -z "$temporary_sudoers" ] || rm -f "$temporary_sudoers"
  [ -z "$temporary_config" ] || rm -f "$temporary_config"
  [ -z "$backup_helper" ] || rm -f "$backup_helper"
  [ -z "$backup_sudoers" ] || rm -f "$backup_sudoers"
}
trap cleanup EXIT HUP INT TERM

validate_config_file() {
  awk -F= '
    /^[[:space:]]*($|#)/ { next }
    {
      key=$1
      if (seen[key]++) exit 1
      value=substr($0,index($0,"=")+1)
      if (length(value) > 513 || value ~ /[\r\n]/) exit 1
      if (key == "schema_version") {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "1" && value != "\"1\"") exit 1
      } else if (key != "ONLY_UPDATE_CHECK" && key != "EXCLUDE_UPDATE_CHECK" &&
                 key != "ONLY" && key != "EXCLUDE") exit 1
    }
    END { exit(seen["schema_version"] ? 0 : 1) }
  ' "$1"
}

[ "$(id -u)" -eq 0 ] || { printf 'external-bootstrap: run as root\n' >&2; exit 70; }
if [ -z "$source_helper" ] || [ ! -f "$source_helper" ] || [ ! -r "$source_helper" ]; then
  printf 'external-bootstrap: readable helper path required\n' >&2
  exit 64
fi
printf '%s\n' "$target_user" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]*$' || {
  printf 'external-bootstrap: valid target user required\n' >&2
  exit 64
}
if [ -e "$CONFIG_PATH" ] && ! validate_config_file "$CONFIG_PATH"; then
  printf 'external-bootstrap: existing local config is invalid; refusing to replace it\n' >&2
  exit 44
fi
if [ -n "$source_config" ] && ! validate_config_file "$source_config"; then
  printf 'external-bootstrap: supplied defaults file is invalid\n' >&2
  exit 64
fi

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

if [ ! -e "$CONFIG_PATH" ]; then
  temporary_config=$(mktemp /tmp/ultimate-updater-external-config.XXXXXX)
  if [ -n "$source_config" ]; then
    if [ ! -f "$source_config" ] || [ ! -r "$source_config" ]; then
      printf 'external-bootstrap: supplied defaults file is not readable\n' >&2
      exit 64
    fi
    cp -- "$source_config" "$temporary_config"
  else
    printf 'schema_version="1"\nONLY_UPDATE_CHECK=""\nEXCLUDE_UPDATE_CHECK=""\nONLY=""\nEXCLUDE=""\n' > "$temporary_config"
  fi
  "$HELPER_PATH" config-write < "$temporary_config" >/dev/null || {
    printf 'external-bootstrap: local config initialization failed\n' >&2
    exit 1
  }
  rm -f "$temporary_config"
  temporary_config=""
fi

printf '%s ALL=(root) NOPASSWD: %s update, %s config-write\n' "$target_user" "$HELPER_PATH" "$HELPER_PATH" > "$temporary_sudoers"
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
printf 'External config initialized or preserved: %s\n' "$CONFIG_PATH"
printf 'Sudo rule installed: %s\n' "$SUDOERS_PATH"
