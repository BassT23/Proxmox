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
  {"id":"guest:988","type":"vm","node":"Proxmox-Test-1","name":"pfsense","updater":"pkg","check_status":"updates_available","reachable":true,"updates":{"available":5},"security_split_supported":false},
  {"id":"guest:986","type":"lxc","node":"Proxmox-Test-2","name":"986","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON

# shellcheck disable=SC1091
LOCAL_FILES="$WORK_DIR" source "$ROOT_DIR/status-model.sh"
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/status.json" > "$WORK_DIR/status-mail"
[[ $(grep -Fc '🖥️ Proxmox-Test-1' "$WORK_DIR/status-mail") -eq 1 ]]
grep -Fq '🐧 984 · unifi' "$WORK_DIR/status-mail"
grep -Fqx 'Security Updates: 4' "$WORK_DIR/status-mail"
grep -Fqx 'Normal Updates: 62' "$WORK_DIR/status-mail"
grep -Fqx 'Security Updates: 10' "$WORK_DIR/status-mail"
grep -Fqx 'Normal Updates: 0' "$WORK_DIR/status-mail"
grep -Fqx 'Security Updates: 0' "$WORK_DIR/status-mail"
grep -Fqx 'Normal Updates: 55' "$WORK_DIR/status-mail"
grep -Fqx 'Security Updates: Unknown' "$WORK_DIR/status-mail"
grep -Fqx 'Normal Updates: 1' "$WORK_DIR/status-mail"
grep -Fqx 'Updates: 5' "$WORK_DIR/status-mail"
grep -Fq 'Total available updates: 137' "$WORK_DIR/status-mail"
[[ $(grep -Fc -- '----------------------------' "$WORK_DIR/status-mail") -eq 5 ]]
python3 - "$WORK_DIR/status-mail" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
separator = "----------------------------"
positions = [index for index, line in enumerate(lines) if line == separator]
assert positions, "no system separators found"
for index in positions[:-1]:
    assert lines[index + 1] != "", "blank line between system blocks"
assert lines[positions[-1] + 1] == ""
total_index = lines.index("Total available updates: 137")
assert total_index == positions[-1] + 2
PY
if grep -Fq '⬆️' "$WORK_DIR/status-mail"; then
  echo 'legacy total-only update lines remain in check mail' >&2
  exit 1
fi
grep -Fqx '🐧 985' "$WORK_DIR/status-mail"
grep -Fqx '✅ 🐧 986' "$WORK_DIR/status-mail"
grep -Fqx '   No updates available' "$WORK_DIR/status-mail"
if grep -Eq 'weitere Systeme|more systems|Systeme geprüft' "$WORK_DIR/status-mail"; then
  echo 'anonymous current aggregation remains in check mail' >&2
  exit 1
fi
if grep -Fq 'host:Proxmox-Test-2' "$WORK_DIR/status-mail"; then
  exit 1
fi

cat > "$WORK_DIR/node-groups.json" <<'JSON'
{"targets":[
  {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"updates_available","reachable":true,"updates":{"available":4},"normal_updates":4,"security_updates":0},
  {"id":"guest:101","type":"lxc","node":"node1","name":"guest-a","check_status":"updates_available","reachable":true,"updates":{"available":2},"normal_updates":2,"security_updates":0},
  {"id":"guest:102","type":"lxc","node":"node1","name":"guest-b","check_status":"updates_available","reachable":true,"updates":{"available":1},"normal_updates":1,"security_updates":0},
  {"id":"host:node2","type":"host","node":"node2","name":"node2","check_status":"updates_available","reachable":true,"updates":{"available":3},"normal_updates":1,"security_updates":2},
  {"id":"guest:201","type":"vm","node":"node2","name":"guest-c","check_status":"updates_available","reachable":true,"updates":{"available":5},"security_split_supported":false},
  {"id":"host:node3","type":"host","node":"node3","name":"node3","check_status":"updates_available","reachable":true,"updates":{"available":1},"normal_updates":1,"security_updates":0}
]}
JSON
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/node-groups.json" > "$WORK_DIR/node-groups-mail"
python3 - "$WORK_DIR/node-groups-mail" <<'PY'
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
headings = ["🖥️ node1", "🖥️ node2", "🖥️ node3"]
positions = [lines.index(heading) for heading in headings]
assert lines[positions[0] - 1] == "", "first node must retain only section spacing"
for position in positions[1:]:
    assert lines[position - 1] == "", "node groups need one blank line"
for left, right in zip(positions, positions[1:]):
    between = lines[left:right]
    assert between.count("") == 1, "node transition must contain exactly one blank line"
guest_a = next(index for index, line in enumerate(lines) if "guest-a" in line)
guest_b = next(index for index, line in enumerate(lines) if "guest-b" in line)
assert lines[guest_a + 3] == "----------------------------"
assert lines[guest_b - 1] == "----------------------------"
PY

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
grep -Fqx '   12 packages updated' "$WORK_DIR/update-status-mail"
grep -Fqx '✅ Proxmox-Test-2' "$WORK_DIR/update-status-mail"
grep -Fqx '   Up to date' "$WORK_DIR/update-status-mail"
grep -Fqx '⚠️ Proxmox-Test-3' "$WORK_DIR/update-status-mail"
grep -Fqx '   Nicht verarbeitet' "$WORK_DIR/update-status-mail" && exit 1
grep -Fqx '   Not reachable' "$WORK_DIR/update-status-mail"
grep -Fqx '❌ 🐧 986 · broken' "$WORK_DIR/update-status-mail"
grep -Fqx '   Update failed' "$WORK_DIR/update-status-mail"
grep -Fqx '⚠️ 🐧 987 · needs-reboot' "$WORK_DIR/update-status-mail"
grep -Fqx '   Updated – reboot required' "$WORK_DIR/update-status-mail"
grep -Fqx '✅ 🐧 985' "$WORK_DIR/update-status-mail"
grep -Fqx '   Up to date' "$WORK_DIR/update-status-mail"
if grep -Eq 'weitere Systeme|more systems|Systeme geprüft' "$WORK_DIR/update-status-mail"; then
  echo 'anonymous current aggregation remains in update mail' >&2
  exit 1
fi

cat > "$WORK_DIR/disabled-status.json" <<'JSON'
{"targets":[
  {"id":"host:proxmox1","type":"host","node":"proxmox1","name":"proxmox1","check_status":"not_checked","reachable":true,"updates":{"available":null},"error":{"code":"CHECK_WITH_HOST_DISABLED","message":"configured off"}},
  {"id":"guest:210","type":"lxc","node":"proxmox1","name":"iobroker","check_status":"not_checked","reachable":true,"updates":{"available":null},"error":{"code":"RUNNING_DISABLED","message":"configured off"}},
  {"id":"guest:211","type":"lxc","node":"proxmox1","name":"broken","check_status":"error","reachable":true,"updates":{"available":null},"error":{"code":"CHECK_COMMAND_FAILED","message":"apt-get update failed"}}
]}
JSON
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/disabled-status.json" update > "$WORK_DIR/disabled-update-mail"
grep -Fqx '💤 proxmox1' "$WORK_DIR/disabled-update-mail"
grep -Fqx '   Check disabled' "$WORK_DIR/disabled-update-mail"
grep -Fqx '💤 🐧 210 · iobroker' "$WORK_DIR/disabled-update-mail"
if grep -Fq 'Ergebnis nicht verfügbar' "$WORK_DIR/disabled-update-mail" ||
  grep -Fq '⚠️ proxmox1' "$WORK_DIR/disabled-update-mail"; then
  echo 'disabled checks must not be rendered as unavailable warnings' >&2
  exit 1
fi
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/disabled-status.json" > "$WORK_DIR/disabled-check-mail"
grep -Fqx '💤 proxmox1' "$WORK_DIR/disabled-check-mail"
grep -Fqx '💤 210 · iobroker' "$WORK_DIR/disabled-check-mail"
grep -Fq '⚠️ 🐧 211 · broken: apt-get update failed' "$WORK_DIR/disabled-check-mail"

cp "$WORK_DIR/update-status.json" "$WORK_DIR/status.json"
LOCAL_FILES="$WORK_DIR" LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; source "$2"; UPDATE_MAIL_BODY' _ \
  "$ROOT_DIR/status-model.sh" "$WORK_DIR/update-mail.sh" > "$WORK_DIR/update-body-mail"
grep -Fqx '✅ Proxmox-Test-2' "$WORK_DIR/update-body-mail"
grep -Fqx '   Up to date' "$WORK_DIR/update-body-mail"

rm -f "$WORK_DIR/status.json"
LOCAL_FILES="$WORK_DIR" HOSTNAME=Proxmox-Test-1 ID=984 NAME=unifi CCONTAINER=true \
  LOG_FILE="$WORK_DIR/log" ERROR_LOG_FILE="$WORK_DIR/errors" EXIT_CODE=0 \
  bash -c 'source "$1"; UPDATE_MAIL_BODY' _ "$WORK_DIR/update-mail.sh" > "$WORK_DIR/legacy-update-mail"
grep -Fqx '✅ Update successful' "$WORK_DIR/legacy-update-mail"
if grep -Eiq 'Erfolgreich|fehlgeschlagen|Neustart erforderlich|Alles aktuell|Pakete aktualisiert' "$WORK_DIR/legacy-update-mail"; then
  echo 'legacy fallback still contains German renderer text' >&2
  exit 1
fi

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
if grep -Eq 'weitere Systeme|more systems|Systeme geprüft' "$WORK_DIR/all-current-mail"; then
  echo 'anonymous current aggregation remains in all-current mail' >&2
  exit 1
fi

# A scoped single-target render must never fall back to unrelated status
# records. This is the core protection for opt-in single-run mail.
STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/update-status.json" update 984 target > "$WORK_DIR/scoped-guest-mail"
grep -Fq '🐧 984 · unifi' "$WORK_DIR/scoped-guest-mail"
if grep -Eq 'Proxmox-Test-[23]|🐧 985|🐧 986|🐧 987|weitere Systeme|Total available updates|Current:' "$WORK_DIR/scoped-guest-mail"; then
  echo 'single-target update mail leaked unrelated status records' >&2
  exit 1
fi

STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/node-groups.json" update node2 node > "$WORK_DIR/scoped-node-mail"
grep -Fq 'node2' "$WORK_DIR/scoped-node-mail"
if grep -Eq 'node1|node3|guest-a|guest-c' "$WORK_DIR/scoped-node-mail"; then
  echo 'single-node mail leaked unrelated status records' >&2
  exit 1
fi

if STATUS_MODEL_RENDER_NOTIFICATION "$WORK_DIR/status.json" invalid >/dev/null 2>&1; then
  exit 1
fi

sender_placeholder="\$USER"
[[ "$(STATUS_MODEL_EXPAND_SENDER "$sender_placeholder")" == "${USER:-$(id -un)}" ]]
[[ "$(STATUS_MODEL_EXPAND_SENDER 'sender@example.test')" == 'sender@example.test' ]]

for mail_file in "$WORK_DIR"/*-mail; do
  if grep -Eiq 'weitere Systeme|more systems|Systeme geprüft|keine Updates verfügbar|Nicht erreichbar|Update fehlgeschlagen|Ergebnis nicht verfügbar|Aktualisiert|Neustart erforderlich|Alles aktuell|Pakete aktualisiert|Erfolgreich aktualisiert' "$mail_file"; then
    echo "German or anonymous renderer literal remains in $mail_file" >&2
    exit 1
  fi
done

echo 'mail renderer tests: PASS'
