#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
CONFIG="$WORK_DIR/web-ui.conf"
trap 'kill "${LISTENER_PID:-0}" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT

printf 'WEB_UI_PORT=8876\n' > "$CONFIG"
[[ "$(WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" get)" == 8876 ]]
WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" ensure >/dev/null
grep -Fxq 'WEB_UI_PORT=8876' "$CONFIG"

printf 'WEB_UI_PORT=8876\nWEB_UI_HTTPS=auto\nWEB_UI_CERT_FILE=/etc/pve/local/pve-ssl.pem\nWEB_UI_KEY_FILE=/etc/pve/local/pve-ssl.key\n' > "$CONFIG"
[[ "$(WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" get)" == 8876 ]]
if [[ "$(id -u)" -eq 0 ]]; then
  WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" set 8877 >/dev/null
  grep -Fxq 'WEB_UI_HTTPS=auto' "$CONFIG"
  grep -Fxq 'WEB_UI_CERT_FILE=/etc/pve/local/pve-ssl.pem' "$CONFIG"
  grep -Fxq 'WEB_UI_KEY_FILE=/etc/pve/local/pve-ssl.key' "$CONFIG"
fi

for invalid in 0 65536 abc -1 8765x ''; do
  if WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" set "$invalid" >/dev/null 2>&1; then
    echo "invalid port accepted: <$invalid>" >&2
    exit 1
  fi
done

PORT_FILE="$WORK_DIR/listener-port"
python3 - "$PORT_FILE" <<'PY' &
import socket
import sys
import time

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen()
with open(sys.argv[1], "w", encoding="ascii") as port_file:
    port_file.write(str(listener.getsockname()[1]))
    port_file.flush()
time.sleep(30)
PY
LISTENER_PID=$!
for _ in {1..50}; do
  [[ -s "$PORT_FILE" ]] && break
  sleep 0.1
done
[[ -s "$PORT_FILE" ]]
LISTENER_PORT=$(<"$PORT_FILE")
printf 'WEB_UI_PORT=%s\n' "$LISTENER_PORT" > "$CONFIG"
if WEB_UI_CONFIG_FILE="$CONFIG" WEB_UI_PORT_OWN_PIDS='' "$ROOT_DIR/web-ui-port.sh" check >/dev/null 2>&1; then
  echo 'foreign listener was not detected' >&2
  exit 1
fi
kill -0 "$LISTENER_PID"
before=$(sha256sum "$CONFIG")
if WEB_UI_CONFIG_FILE="$CONFIG" WEB_UI_PORT_OWN_PIDS='' "$ROOT_DIR/web-ui-port.sh" set 18765 >/dev/null 2>&1; then
  echo 'port setter accepted a foreign listener' >&2
  exit 1
fi
[[ "$before" == "$(sha256sum "$CONFIG")" ]]
WEB_UI_CONFIG_FILE="$CONFIG" WEB_UI_PORT_OWN_PIDS="$LISTENER_PID" "$ROOT_DIR/web-ui-port.sh" check >/dev/null

if [[ "$(id -u)" -eq 0 ]]; then
  WEB_UI_CONFIG_FILE="$CONFIG" "$ROOT_DIR/web-ui-port.sh" set 8877 >/dev/null
  grep -Fxq 'WEB_UI_PORT=8877' "$CONFIG"
fi

grep -Fq 'mktemp' "$ROOT_DIR/web-ui-port.sh"
grep -Fq 'mv -f' "$ROOT_DIR/web-ui-port.sh"
echo 'Web UI port safety tests: PASS'
