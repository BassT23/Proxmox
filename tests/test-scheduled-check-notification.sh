#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[{"id":"guest:910","type":"lxc","name":"debian12","node":"Test-Cluster","check_status":"updates_available","reachable":true,"updates":{"available":1},"normal_updates":1,"security_updates":0}]}
JSON
cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="test-recipient"
EMAIL_SENDER="test-sender"
EMAIL_NO_UPDATES="true"
EMAIL_ONLY_SECURITY="false"
EMAIL_ONLY_ERROR="false"
EMAIL_SINGLE_RUNS="false"
EMAIL_DAILY_CHECK="false"
EOF
cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
cat > "${MAIL_CAPTURE:?}"
EOF
chmod +x "$WORK_DIR/mail"

export LOCAL_FILES="$WORK_DIR" STATUS_MODEL_FILE="$WORK_DIR/status.json"
export PATH="$WORK_DIR:$PATH" MAIL_CAPTURE="$WORK_DIR/captured-mail" HOSTNAME=Test-Cluster
# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"
grep -Fq 'scheduled_email_enabled' "$ROOT_DIR/check-updates.sh"

# Scheduled checks are gated by EMAIL_DAILY_CHECK.
export UU_JOB_SOURCE=scheduler
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ ! -e "$WORK_DIR/captured-mail" ]]

sed -i 's/EMAIL_DAILY_CHECK="false"/EMAIL_DAILY_CHECK="true"/' "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -e "$WORK_DIR/captured-mail" ]]

# A missing key retains the compatible default of true.
rm -f "$WORK_DIR/captured-mail"
sed -i '/EMAIL_DAILY_CHECK=/d' "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -e "$WORK_DIR/captured-mail" ]]

# Manual global checks are independent of EMAIL_DAILY_CHECK.
rm -f "$WORK_DIR/captured-mail"
unset UU_JOB_SOURCE
printf 'EMAIL_DAILY_CHECK="false"\n' >> "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -e "$WORK_DIR/captured-mail" ]]

# Manual single-target runs remain controlled by EMAIL_SINGLE_RUNS, not the
# scheduled-check setting.
rm -f "$WORK_DIR/captured-mail"
export UU_SINGLE_TARGET=true UU_SINGLE_TARGET_ID=910 UU_SINGLE_TARGET_KIND=target
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ ! -e "$WORK_DIR/captured-mail" ]]

sed -i 's/EMAIL_SINGLE_RUNS="false"/EMAIL_SINGLE_RUNS="true"/' "$WORK_DIR/update.conf"
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
grep -Fq '910 · debian12' "$WORK_DIR/captured-mail"

# Updates are not controlled by EMAIL_DAILY_CHECK.
rm -f "$WORK_DIR/captured-mail"
unset UU_SINGLE_TARGET UU_SINGLE_TARGET_ID UU_SINGLE_TARGET_KIND
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ -e "$WORK_DIR/captured-mail" ]]

echo 'scheduled check notification tests: PASS'
