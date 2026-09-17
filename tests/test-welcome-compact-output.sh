#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{
  "schema_version": 1,
  "generated_at": "2026-09-16T12:00:00Z",
  "targets": [
    {"id":"host:node1","type":"host","node":"node1","name":"node1","check_status":"updates_available","reachable":true,"normal_updates":104,"security_updates":19,"updates":{"available":123},"reboot_required":false},
    {"id":"guest:110","type":"lxc","name":"git-repo","node":"node1","check_status":"updates_available","reachable":true,"normal_updates":48,"security_updates":3,"updates":{"available":51},"reboot_required":false},
    {"id":"guest:100","type":"vm","name":"pfsense","node":"node1","check_status":"updates_available","reachable":true,"updates":{"available":1},"reboot_required":false},
    {"id":"guest:340","type":"vm","name":"Kubuntu-VM","node":"node1","check_status":"updates_available","reachable":true,"normal_updates":56,"security_updates":0,"updates":{"available":56},"reboot_required":true},
    {"id":"guest:102","type":"vm","name":"old-pbs","node":"node1","check_status":"not_checked","reachable":null,"updates":{"available":null}},
    {"id":"guest:130","type":"lxc","name":"GameServer","node":"node1","check_status":"skipped","reachable":false,"updates":{"available":null}},
    {"id":"guest:140","type":"vm","name":"inventory-only","node":"node1","check_status":"stopped","reachable":false,"updates":{"available":null}},
    {"id":"guest:150","type":"vm","name":"broken","node":"node1","check_status":"error","reachable":true,"updates":{"available":null},"error":{"code":"CHECK_FAILED","message":"repository check failed"}},
    {"id":"guest:160","type":"vm","name":"offline","node":"node1","check_status":"offline","reachable":false,"updates":{"available":null},"error":{"code":"OFFLINE","message":"connection unavailable"}},
    {"id":"guest:111","type":"lxc","name":"second","node":"node1","check_status":"ok","reachable":true,"normal_updates":0,"security_updates":0,"updates":{"available":0}},
    {"id":"host:node2","type":"host","node":"node2","name":"node2","check_status":"updates_available","reachable":true,"normal_updates":2,"security_updates":1,"updates":{"available":3}},
    {"id":"guest:210","type":"lxc","name":"storage","node":"node2","check_status":"updates_available","reachable":true,"updates":{"available":1}},
    {"id":"guest:200","type":"lxc","name":"media","node":"node2","check_status":"updates_available","reachable":true,"updates":{"available":2}},
    {"id":"guest:220","type":"vm","name":"windows","node":"node2","check_status":"updates_available","reachable":true,"updates":{"available":1},"reboot_required":true},
    {"id":"guest:230","type":"lxc","name":"very-long-container-name-for-layout-testing","node":"node2","check_status":"updates_available","reachable":true,"normal_updates":7,"security_updates":2,"updates":{"available":9}},
    {"id":"host:node3","type":"host","node":"node3","name":"node3","check_status":"ok","reachable":true,"normal_updates":0,"security_updates":0,"updates":{"available":0}},
    {"id":"guest:971","type":"vm","name":"healthy","node":"node3","check_status":"updates_available","reachable":true,"updates":{"available":3}},
    {"id":"guest:310","type":"vm","name":"unreachable","node":"node3","check_status":"offline","reachable":false,"updates":{"available":null}},
    {"id":"guest:340","type":"vm","name":"failed","node":"node3","check_status":"error","reachable":true,"updates":{"available":null},"error":{"code":"CHECK_FAILED","message":"guest check failed"}},
    {"id":"external:med","type":"external","name":"Mediacenter","node":"","check_status":"offline","reachable":false,"updates":{"available":null}},
    {"id":"external:ext-1","type":"external","name":"Backup service","node":"","check_status":"updates_available","reachable":true,"updates":{"available":4}}
  ]
}
JSON

cat > "$WORK_DIR/raw-a" <<'EOF'
Fetched 544 kB in 1s (544 kB/s)
Es wurden 10,5 MB in 4 s geholt (2.950 kB/s).
Téléchargé; Descargado; nonsense package chatter
EOF
cat > "$WORK_DIR/raw-b" <<'EOF'
Paketlisten werden gelesen…
Scaricato; Pobrano; arbitrary localized output
EOF

export LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json"
# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

cp "$WORK_DIR/raw-a" "$WORK_DIR/check-output"
output_a=$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status.json")
cp "$WORK_DIR/raw-b" "$WORK_DIR/check-output"
output_b=$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status.json")
[[ "$output_a" == "$output_b" ]]

for noise in 'Fetched' 'Es wurden' 'geholt' 'kB/s' 'MB/s'; do
  if grep -Fq "$noise" <<<"$output_a"; then
    echo "external APT chatter leaked into structured Welcome output: $noise" >&2
    exit 1
  fi
done

line() { grep -n -F "$1" <<<"$output_a" | head -n1 | cut -d: -f1; }
[[ "$(line 'node1  S:19 N:104')" -lt "$(line '  100 pfsense')" ]]
[[ "$(line 'node2  S:1 N:2')" -lt "$(line '  200 media')" ]]
[[ "$(line '  200 media')" -lt "$(line '  210 storage')" ]]
[[ "$(line 'node3')" -lt "$(line '  971 healthy')" ]]
[[ "$(line '  100 pfsense')" -lt "$(line '  110 git-repo')" ]]
[[ "$(line '  110 git-repo')" -lt "$(line '  340 Kubuntu-VM')" ]]
[[ "$(line 'External')" -lt "$(line '  ext-1 Backup service')" ]]
long_line=$(grep -E '^  230 very-long-container.*\.\.\.' <<<"$output_a" | head -n1)
[[ -n "$long_line" ]]
[[ "$(line '  230')" -gt "$(line '  220 windows')" ]]

# Color is opt-in for deterministic non-TTY tests, and is applied only while
# rendering; the status JSON above remains free of ANSI escape sequences.
colored=$(UU_WELCOME_COLOR=always bash -c 'source "$1"; STATUS_MODEL_RENDER_WELCOME "$2"' _ "$ROOT_DIR/status-model.sh" "$WORK_DIR/status.json")
grep -Fq $'\033[36mnode1\033[0m' <<<"$colored"
grep -Fq $'\033[1;92m  100 pfsense' <<<"$colored"
grep -Fq $'\033[1;33mS:19\033[0m' <<<"$colored"
grep -Fq $'\033[1;33mReboot\033[0m' <<<"$colored"
if grep -q $'\033' "$WORK_DIR/status.json"; then
  echo 'ANSI escape sequence leaked into structured status data' >&2
  exit 1
fi
for expected in \
  'node1  S:19 N:104' \
  '  100 pfsense' \
  '  110 git-repo' \
  '  340 Kubuntu-VM' \
  '  340 Kubuntu-VM' \
  'Reboot' \
  'node2  S:1 N:2' \
  '  200 media' \
  '  230 very-long-container' \
  'node3' \
  '  971 healthy' \
  'External' \
  '  ext-1 Backup service'; do
  grep -Fq "$expected" <<<"$output_a" || {
    echo "structured Welcome summary is missing: $expected" >&2
    exit 1
  }
done
grep -Eq '^  100 pfsense +Updates:1' <<<"$output_a"
grep -Eq '^  ext-1 Backup service +Updates:4' <<<"$output_a"

for excluded in 'old-pbs' 'GameServer' 'inventory-only' 'broken' 'offline' \
  'Status: Check failed' 'Status: Offline' 'Mediacenter' '  111 second' \
  '  105'; do
  if grep -Fq "$excluded" <<<"$output_a"; then
    echo "non-current Welcome entry leaked into summary: $excluded" >&2
    exit 1
  fi
done

plain=$(UU_WELCOME_COLOR=never STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status.json")
if grep -q $'\033' <<<"$plain"; then
  echo 'ANSI escape sequence leaked with color=never' >&2
  exit 1
fi
for columns in 40 60 80 120; do
  width_output=$(COLUMNS="$columns" UU_WELCOME_COLOR=never STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status.json")
  if grep -Eq $'\033\[[0-9;]*[HfGJK]' <<<"$width_output"; then
    echo "cursor control sequence emitted at COLUMNS=$columns" >&2
    exit 1
  fi
done

# Internal target selection must suppress legacy tag warnings.  The source
# contract also ensures the setting is read from update.conf before the tag
# filter is applied.
grep -Fq 'USE_INTERNAL_TARGET_SELECTION=$(awk' "$ROOT_DIR/welcome-screen.sh"
grep -Fq 'Target selection is active. Not all systems may be checked.' "$ROOT_DIR/welcome-screen.sh"

cat > "$WORK_DIR/update.conf" <<'EOF'
USED_BRANCH="develop"
CHECK_WITH_HOST="true"
CHECK_WITH_LXC="true"
CHECK_WITH_VM="true"
CHECK_RUNNING_CONTAINER="true"
CHECK_STOPPED_CONTAINER="true"
EXCLUDE_UPDATE_CHECK="update-exclude"
ONLY_UPDATE_CHECK=""
USE_INTERNAL_TARGET_SELECTION="true"
EOF
cat > "$WORK_DIR/update.sh" <<'EOF'
VERSION="5.1.3"
EOF
cp "$ROOT_DIR/tag-filter.sh" "$WORK_DIR/tag-filter.sh"
cp "$ROOT_DIR/target-selection.sh" "$WORK_DIR/target-selection.sh"
cp "$ROOT_DIR/status-model.sh" "$WORK_DIR/status-model.sh"
cat > "$WORK_DIR/target-selection.json" <<'JSON'
{"schema_version":1,"check":{"guest:210":"exclude"},"update":{}}
JSON
welcome=$(LOCAL_FILES="$WORK_DIR" VERSION_CACHE_FILE="$WORK_DIR/no-cache" bash "$ROOT_DIR/welcome-screen.sh")
if grep -Fq 'Exclude is set.' <<<"$welcome"; then
  echo 'legacy exclusion warning leaked while internal selection is active' >&2
  exit 1
fi
grep -Fq 'Target selection is active.' <<<"$welcome"

printf '{broken-json\n' > "$WORK_DIR/status-invalid.json"
[[ "$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status-invalid.json")" == "Update status unavailable." ]]
rm -f "$WORK_DIR/status-missing.json"
[[ "$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status-missing.json")" == "Update status unavailable." ]]

printf '%s\n' 'welcome structured output tests: PASS'
