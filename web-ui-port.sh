#!/bin/bash

set -euo pipefail

WEB_UI_CONFIG_FILE="${WEB_UI_CONFIG_FILE:-/etc/ultimate-updater/web-ui.conf}"
WEB_UI_DEFAULT_PORT=8765

usage() { printf 'Usage: %s get | set PORT | ensure | check\n' "$0" >&2; }

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

read_port() {
  local value="" line key
  [[ -f "$WEB_UI_CONFIG_FILE" && -r "$WEB_UI_CONFIG_FILE" ]] || { printf '%s\n' "$WEB_UI_DEFAULT_PORT"; return; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" || "$line" == \#* ]] && continue
    [[ "$line" == *=* ]] || { printf 'Invalid Web UI config line\n' >&2; return 64; }
    key=${line%%=*}
    [[ "$key" == WEB_UI_PORT ]] || { printf 'Unsupported Web UI config key: %s\n' "$key" >&2; return 64; }
    [[ -z "$value" ]] || { printf 'Duplicate WEB_UI_PORT setting\n' >&2; return 64; }
    value=${line#*=}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
  done < "$WEB_UI_CONFIG_FILE"
  [[ -n "$value" ]] || { printf 'WEB_UI_PORT is missing\n' >&2; return 64; }
  valid_port "$value" || { printf 'Invalid WEB_UI_PORT: %s\n' "$value" >&2; return 64; }
  printf '%s\n' "$((10#$value))"
}

own_pids() {
  if [[ -n "${WEB_UI_PORT_OWN_PIDS:-}" ]]; then
    printf '%s\n' "$WEB_UI_PORT_OWN_PIDS" | tr ',' '\n'
    return
  fi
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl show -p MainPID --value ultimate-updater-web.service 2>/dev/null || true
}

port_listener_pids() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || {
    printf 'Cannot validate Web UI port: ss is unavailable.\n' >&2
    return 69
  }
  ss -H -ltnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
}

port_available() {
  local port="$1" pid own matched
  local -a owners=()
  while IFS= read -r pid; do [[ -n "$pid" ]] && owners+=("$pid"); done < <(port_listener_pids "$port")
  ((${#owners[@]} == 0)) && return 0
  for pid in "${owners[@]}"; do
    matched=false
    while IFS= read -r own; do [[ -n "$own" && "$pid" == "$own" ]] && matched=true; done < <(own_pids)
    if [[ "$matched" != true ]]; then
      printf 'Web UI port %s is already in use by another process.\n' "$port" >&2
      printf 'Ultimate Updater did not stop or modify the existing service.\n' >&2
      printf 'Set another port with: ultimate-updater config set web-port PORT\n' >&2
      return 73
    fi
  done
}

write_config() {
  local port="$1" directory temporary
  [[ "$(id -u)" -eq 0 ]] || { printf 'Web UI port configuration requires root.\n' >&2; return 70; }
  directory=${WEB_UI_CONFIG_FILE%/*}
  install -d -o root -g root -m 0755 "$directory"
  temporary=$(mktemp "$WEB_UI_CONFIG_FILE.tmp.XXXXXX")
  printf 'WEB_UI_PORT=%s\n' "$port" > "$temporary"
  chown root:root "$temporary"; chmod 0644 "$temporary"
  mv -f "$temporary" "$WEB_UI_CONFIG_FILE"
}

ensure_config() {
  local port
  if [[ ! -e "$WEB_UI_CONFIG_FILE" ]]; then
    write_config "$WEB_UI_DEFAULT_PORT"
    printf 'Web UI port %s configured (default).\n' "$WEB_UI_DEFAULT_PORT"
  else
    port=$(read_port)
    printf 'Using configured Web UI port %s.\n' "$port"
  fi
}

case "${1:-}" in
  get) [[ $# -eq 1 ]] || { usage; exit 2; }; read_port ;;
  set)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    valid_port "$2" || { printf 'Invalid Web UI port: %s (expected 1-65535)\n' "$2" >&2; exit 64; }
    port_available "$((10#$2))"
    write_config "$((10#$2))"
    printf 'Web UI port %s configured. Restart ultimate-updater-web.service to apply it.\n' "$((10#$2))"
    ;;
  ensure) [[ $# -eq 1 ]] || { usage; exit 2; }; ensure_config ;;
  check) [[ $# -eq 1 ]] || { usage; exit 2; }; port=$(read_port); port_available "$port"; printf 'Web UI port %s available.\n' "$port" ;;
  *) usage; exit 2 ;;
esac
