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
  {"id":"host:Proxmox-Test-1","type":"host","node":"Proxmox-Test-1","name":"Proxmox-Test-1","check_status":"updates_available","reachable":true,"updates":{"available":66},"normal_updates":62,"security_updates":4},
  {"id":"host:Proxmox-Test-2","type":"unknown","node":"Proxmox-Test-2","check_status":"ok","reachable":true,"updates":{"available":0}},
  {"id":"guest:984","type":"lxc","node":"Proxmox-Test-1","name":"unifi","check_status":"updates_available","reachable":true,"updates":{"available":10},"normal_updates":0,"security_updates":10},
  {"id":"guest:985","type":"lxc","node":"Proxmox-Test-1","name":"985","check_status":"updates_available","reachable":true,"updates":{"available":55},"normal_updates":55,"security_updates":0},
  {"id":"guest:987","type":"lxc","node":"Proxmox-Test-1","name":"unknown-security","check_status":"updates_available","reachable":true,"updates":{"available":1},"normal_updates":1,"security_updates":null},
  {"id":"guest:986","type":"lxc","node":"Proxmox-Test-2","name":"986","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON

# shellcheck disable=SC1091
LOCAL_FILES="$WORK_DIR" source "$ROOT_DIR/status-model.sh"
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/status.json" > "$WORK_DIR/status-mail"
[[ $(grep -Fc '🖥️ Proxmox-Test-1' "$WORK_DIR/status-mail") -eq 1 ]]
grep -Fq '🐧 984 · unifi' "$WORK_DIR/status-mail"
grep -Fqx 'S: 4 / N: 62' "$WORK_DIR/status-mail"
grep -Fqx 'S: 10 / N: 0' "$WORK_DIR/status-mail"
grep -Fqx 'S: 0 / N: 55' "$WORK_DIR/status-mail"
grep -Fqx 'S: Unknown / N: 1' "$WORK_DIR/status-mail"
grep -Fq 'Total available updates: 132' "$WORK_DIR/status-mail"
if grep -Fq '⬆️' "$WORK_DIR/status-mail"; then
  echo 'legacy total-only update lines remain in check mail' >&2
  exit 1
fi
grep -Fqx '🐧 985' "$WORK_DIR/status-mail"
[[ $(grep -Fc '✅ 2 weitere Systeme geprüft – keine Updates verfügbar' "$WORK_DIR/status-mail") -eq 1 ]]
if grep -Fq 'host:Proxmox-Test-2' "$WORK_DIR/status-mail"; then
  exit 1
fi

cat > "$WORK_DIR/update-status.json" <<'JSON'
{"targets":[
  {"id":"host:Proxmox-Test-1","type":"host","node":"Proxmox-Test-1","name":"Proxmox-Test-1","check_status":"updates_available","reachable":true,"updates":{"available":12},"last_update":{"status":"success","exit_code":0,"updated_packages":12}},
  {"id":"host:Proxmox-Test-2","type":"host","node":"Proxmox-Test-2","name":"Proxmox-Test-2","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"host:Proxmox-Test-3","type":"host","node":"Proxmox-Test-3","name":"Proxmox-Test-3","check_status":"offline","reachable":false,"updates":{"available":null}},
  {"id":"guest:984","type":"lxc","node":"Proxmox-Test-1","name":"unifi","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"guest:985","type":"lxc","node":"Proxmox-Test-2","name":"985","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"guest:986","type":"lxc","node":"Proxmox-Test-2","name":"broken","check_status":"error","reachable":true,"updates":{"available":3},"last_update":{"status":"failed","exit_code":17}},
  {"id":"guest:987","type":"lxc","node":"Proxmox-Test-2","name":"needs-reboot","check_status":"ok","reachable":true,"updates":{"available":1},"reboot_required":true,"last_update":{"status":"success","exit_code":0}}
]}
JSON
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/update-status.json" update > "$WORK_DIR/update-status-mail"
grep -Fqx '✅ Proxmox-Test-1' "$WORK_DIR/update-status-mail"
grep -Fqx '   12 Pakete aktualisiert' "$WORK_DIR/update-status-mail"
grep -Fqx '✅ Proxmox-Test-2' "$WORK_DIR/update-status-mail"
grep -Fqx '   Alles aktuell' "$WORK_DIR/update-status-mail"
grep -Fqx '⚠️ Proxmox-Test-3' "$WORK_DIR/update-status-mail"
grep -Fqx '   Nicht verarbeitet' "$WORK_DIR/update-status-mail" && exit 1
grep -Fqx '   Nicht erreichbar' "$WORK_DIR/update-status-mail"
grep -Fqx '❌ 🐧 986 · broken' "$WORK_DIR/update-status-mail"
grep -Fqx '   Update fehlgeschlagen' "$WORK_DIR/update-status-mail"
grep -Fqx '⚠️ 🐧 987 · needs-reboot' "$WORK_DIR/update-status-mail"
grep -Fqx '   Aktualisiert – Neustart erforderlich' "$WORK_DIR/update-status-mail"
[[ $(grep -Fc '✅ 2 weitere Systeme – alles aktuell' "$WORK_DIR/update-status-mail") -eq 1 ]]

cp "$WORK_DIR/update-status.json" "$WORK_DIR/status.json"
LOCAL_FILES="$WORK_DIR" LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; source "$2"; UPDATE_MAIL_BODY' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/update-mail.sh" > "$WORK_DIR/update-body-mail"
grep -Fqx '✅ Proxmox-Test-2' "$WORK_DIR/update-body-mail"
grep -Fqx '   Alles aktuell' "$WORK_DIR/update-body-mail"

LOCAL_FILES="$WORK_DIR" SINGLE_UPDATE=true HOSTNAME=Proxmox-Test-1 ID=984 NAME=unifi \
  CCONTAINER=true LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; source "$2"; UPDATE_MAIL_BODY' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/update-mail.sh" > "$WORK_DIR/single-update-mail"
grep -Fq '🐧 984 · unifi' "$WORK_DIR/single-update-mail"
if grep -Fq '✅ Proxmox-Test-2' "$WORK_DIR/single-update-mail"; then
  exit 1
fi

cat > "$WORK_DIR/all-current-status.json" <<'JSON'
{"targets":[
  {"id":"host:Proxmox-Test-1","type":"host","node":"Proxmox-Test-1","name":"Proxmox-Test-1","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"host:Proxmox-Test-2","type":"host","node":"Proxmox-Test-2","name":"Proxmox-Test-2","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"host:Proxmox-Test-3","type":"host","node":"Proxmox-Test-3","name":"Proxmox-Test-3","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}}
]}
JSON
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/all-current-status.json" update > "$WORK_DIR/all-current-mail"
for node in Proxmox-Test-1 Proxmox-Test-2 Proxmox-Test-3; do
  grep -Fqx "✅ $node" "$WORK_DIR/all-current-mail"
done
[[ $(grep -Fc '✅ Proxmox-Test-' "$WORK_DIR/all-current-mail") -eq 3 ]]

if STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/status.json" invalid >/dev/null 2>&1; then
  exit 1
fi

sender_placeholder="\$USER"
[[ "$(STATUS_MODEL_EXPAND_SENDER "$sender_placeholder")" == "${USER:-$(id -un)}" ]]
[[ "$(STATUS_MODEL_EXPAND_SENDER 'sender@example.test')" == 'sender@example.test' ]]

echo 'mail renderer tests: PASS'
