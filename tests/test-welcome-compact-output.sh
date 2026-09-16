#!/usr/bin/env bash
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
    {"id":"guest:340","type":"vm","name":"Kubuntu-VM","node":"node1","check_status":"updates_available","reachable":true,"normal_updates":56,"security_updates":0,"updates":{"available":56},"reboot_required":true}
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
for expected in \
  'Host : node1' \
  'S: 19 / N: 104' \
  'LXC 110 : git-repo' \
  'S: 3 / N: 48' \
  'VM 100 : pfsense' \
  'Updates: 1' \
  'VM 340 : Kubuntu-VM' \
  'Reboot required' \
  'S: 0 / N: 56'; do
  grep -Fq "$expected" <<<"$output_a" || {
    echo "structured Welcome summary is missing: $expected" >&2
    exit 1
  }
done

printf '{broken-json\n' > "$WORK_DIR/status-invalid.json"
[[ "$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status-invalid.json")" == "Update status unavailable." ]]
rm -f "$WORK_DIR/status-missing.json"
[[ "$(STATUS_MODEL_RENDER_WELCOME "$WORK_DIR/status-missing.json")" == "Update status unavailable." ]]

printf '%s\n' 'welcome structured output tests: PASS'
