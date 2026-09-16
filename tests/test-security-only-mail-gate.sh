#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="test-recipient"
EMAIL_SENDER="test-sender"
EMAIL_NO_UPDATES="false"
EMAIL_ONLY_SECURITY="true"
EMAIL_DAILY_CHECK="true"
EMAIL_SINGLE_RUNS="true"
EOF
cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
cat > "${MAIL_CAPTURE:?}"
EOF
chmod +x "$WORK_DIR/mail"

export LOCAL_FILES="$WORK_DIR" PATH="$WORK_DIR:$PATH" HOSTNAME=test-host
export UU_JOB_SOURCE=scheduler MAIL_CAPTURE="$WORK_DIR/mail-output"
# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"guest:110","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":2},"normal_updates":2,"security_updates":1}]}
JSON
printf 'ordinary output without the letter S\n' > "$WORK_DIR/check-output"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -s "$WORK_DIR/mail-output" ]]

rm -f "$WORK_DIR/mail-output"
cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"guest:110","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":2},"normal_updates":2,"security_updates":0}]}
JSON
printf 'S S S S S\n' > "$WORK_DIR/check-output"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ ! -e "$WORK_DIR/mail-output" ]]

rm -f "$WORK_DIR/mail-output"
cat > "$WORK_DIR/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"guest:110","type":"lxc","name":"fixture","check_status":"error","reachable":false,"updates":{"available":null},"normal_updates":null,"security_updates":null,"error":{"code":"CHECK_FAILED","message":"unknown"}}]}
JSON
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ ! -e "$WORK_DIR/mail-output" ]]

printf '%s\n' 'security-only structured mail gate tests: PASS'
