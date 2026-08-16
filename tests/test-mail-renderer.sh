#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

printf '0 upgraded\n' > "$WORK_DIR/log"
: > "$WORK_DIR/errors"
awk '/^UPDATE_MAIL_BODY\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-mail.sh"

HOSTNAME=Proxmox-Test-1 ID=Proxmox-Test-1 NAME=Proxmox-Test-1 \
  LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; UPDATE_MAIL_BODY' _ "$WORK_DIR/update-mail.sh" > "$WORK_DIR/host-mail"
grep -Fqx '🖥️ Proxmox-Test-1' "$WORK_DIR/host-mail" -m1
if grep -Fq '🐧 Proxmox-Test-1' "$WORK_DIR/host-mail"; then
  exit 1
fi

HOSTNAME=Proxmox-Test-1 ID=984 NAME=unifi CCONTAINER=true \
  LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; UPDATE_MAIL_BODY' _ "$WORK_DIR/update-mail.sh" > "$WORK_DIR/lxc-mail"
grep -Fq '🐧 984 · unifi' "$WORK_DIR/lxc-mail"

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"host:Proxmox-Test-1","type":"host","node":"Proxmox-Test-1","name":"Proxmox-Test-1","check_status":"updates_available","reachable":true,"updates":{"available":23}},
  {"id":"guest:984","type":"lxc","node":"Proxmox-Test-1","name":"unifi","check_status":"updates_available","reachable":true,"updates":{"available":99}},
  {"id":"guest:985","type":"lxc","node":"Proxmox-Test-1","name":"985","check_status":"updates_available","reachable":true,"updates":{"available":1}}
]}
JSON

# shellcheck disable=SC1091
LOCAL_FILES="$WORK_DIR" source "$ROOT_DIR/status-model.sh"
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/status.json" > "$WORK_DIR/status-mail"
[[ $(grep -Fc '🖥️ Proxmox-Test-1' "$WORK_DIR/status-mail") -eq 1 ]]
grep -Fq '🐧 984 · unifi' "$WORK_DIR/status-mail"
grep -Fqx '🐧 985' "$WORK_DIR/status-mail"

sender_placeholder="\$USER"
[[ "$(STATUS_MODEL_EXPAND_SENDER "$sender_placeholder")" == "${USER:-$(id -un)}" ]]
[[ "$(STATUS_MODEL_EXPAND_SENDER 'sender@example.test')" == 'sender@example.test' ]]

echo 'mail renderer tests: PASS'
