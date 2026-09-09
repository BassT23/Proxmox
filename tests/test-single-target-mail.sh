#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"guest:900","type":"lxc","name":"pihole","check_status":"error","reachable":true,"error":{"code":"CHECK_COMMAND_FAILED","message":"apt failed"},"last_update":{"status":"failed","exit_code":1}},
  {"id":"guest:920","type":"lxc","name":"debian","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}},
  {"id":"host:Proxmox-Test-1","type":"host","node":"Proxmox-Test-1","name":"Proxmox-Test-1","check_status":"ok","reachable":true,"updates":{"available":0},"last_update":{"status":"success","exit_code":0}}
]}
JSON
cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="test-recipient"
EMAIL_SENDER="test-sender"
EMAIL_SINGLE_RUNS="false"
EMAIL_ONLY_ERROR="false"
EMAIL_NO_UPDATES="false"
EOF
cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
cat > "${MAIL_CAPTURE:?}"
EOF
chmod +x "$WORK_DIR/mail"

export LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json"
export PATH="$WORK_DIR:$PATH" MAIL_CAPTURE="$WORK_DIR/captured-mail"
# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

export UU_SINGLE_TARGET=true UU_SINGLE_TARGET_ID=900 UU_SINGLE_TARGET_KIND=target
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ ! -e "$WORK_DIR/captured-mail" ]]

sed -i 's/EMAIL_SINGLE_RUNS="false"/EMAIL_SINGLE_RUNS="true"/' "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
grep -Fq '900 · pihole' "$WORK_DIR/captured-mail"
if grep -Eq '920 · debian|Proxmox-Test-1|weitere Systeme|Current:' "$WORK_DIR/captured-mail"; then
  echo 'single-target notification leaked global records' >&2
  exit 1
fi

rm -f "$WORK_DIR/captured-mail"
unset UU_SINGLE_TARGET UU_SINGLE_TARGET_ID UU_SINGLE_TARGET_KIND
sed -i 's/EMAIL_SINGLE_RUNS="true"/EMAIL_SINGLE_RUNS="false"/' "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -e "$WORK_DIR/captured-mail" ]]

echo 'single-target mail tests: PASS'
