#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/captures"
printf '0\n' > "$WORK_DIR/count"
cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(<"$MAIL_COUNTER")
count=$((count + 1))
printf '%s\n' "$count" > "$MAIL_COUNTER"
printf '%s\n' "$*" > "$MAIL_CAPTURE_DIR/$count.args"
cat > "$MAIL_CAPTURE_DIR/$count.body"
EOF
chmod +x "$WORK_DIR/mail"

export LOCAL_FILES="$WORK_DIR"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
export PATH="$WORK_DIR:$PATH"
export MAIL_COUNTER="$WORK_DIR/count"
export MAIL_CAPTURE_DIR="$WORK_DIR/captures"

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

long_line=$(printf 'x%.0s' {1..400})
quoted_line=$(printf '%s %s' '"VM Name"' "'quoted'")
body=$(printf '%s\n' \
  '<node>' \
  'A&B' \
  "$quoted_line" \
  '' \
  '  indented line' \
  'Umlaute: äöü 😀' \
  "$long_line")
printf '%s\n' "$body" |
  STATUS_MODEL_SEND_HTML_MAIL 'Subject' 'sender@example.test' 'recipient@example.test'

[[ $(<"$WORK_DIR/count") == 1 ]]
grep -Fq 'Content-Type: text/html; charset=UTF-8' "$WORK_DIR/captures/1.args"
grep -Fq 'Content-Transfer-Encoding: 8bit' "$WORK_DIR/captures/1.args"
grep -Fq -- '-r sender@example.test' "$WORK_DIR/captures/1.args"
grep -Fq -- '-s Subject' "$WORK_DIR/captures/1.args"
grep -Fq 'recipient@example.test' "$WORK_DIR/captures/1.args"
grep -Fq '<!doctype html><html><body' "$WORK_DIR/captures/1.body"
grep -Fq 'white-space:pre-wrap' "$WORK_DIR/captures/1.body"
grep -Fq 'overflow-wrap:anywhere' "$WORK_DIR/captures/1.body"
grep -Fq '&lt;node&gt;' "$WORK_DIR/captures/1.body"
grep -Fq 'A&amp;B' "$WORK_DIR/captures/1.body"
grep -Fq '&quot;VM Name&quot;' "$WORK_DIR/captures/1.body"
grep -Fq '&#x27;quoted&#x27;' "$WORK_DIR/captures/1.body"
grep -Fq '&nbsp;' "$WORK_DIR/captures/1.body"
grep -Fq '  indented line' "$WORK_DIR/captures/1.body"
grep -Fq 'Umlaute: äöü 😀' "$WORK_DIR/captures/1.body"
if grep -Fq '<node>' "$WORK_DIR/captures/1.body"; then
  echo 'unescaped HTML markup found in mail body' >&2
  exit 1
fi

# Header values are configuration-derived mail headers and must not accept
# embedded line breaks.
if printf '%s\n' 'body' |
  STATUS_MODEL_SEND_HTML_MAIL $'bad\nX-Injected: yes' sender@example.test recipient@example.test; then
  echo 'header injection was accepted' >&2
  exit 1
fi
[[ $(<"$WORK_DIR/count") == 1 ]]

: | STATUS_MODEL_SEND_HTML_MAIL 'Empty' sender@example.test recipient@example.test
[[ $(<"$WORK_DIR/count") == 2 ]]
grep -Fq '&nbsp;' "$WORK_DIR/captures/2.body"

cat > "$WORK_DIR/status.json" <<'JSON'
{"targets":[
  {"id":"guest:986","type":"lxc","name":"mail-test","check_status":"updates_available","reachable":true,"updates":{"available":1},"last_update":{"status":"success","exit_code":0,"updated_packages":1,"pending_before":1}}
]}
JSON
cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="recipient@example.test"
EMAIL_SENDER="sender@example.test"
EMAIL_DAILY_CHECK="true"
EMAIL_SINGLE_RUNS="true"
EMAIL_NO_UPDATES="false"
EMAIL_ONLY_SECURITY="false"
EMAIL_ONLY_ERROR="false"
EOF

HOSTNAME=mail-test STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ $(<"$WORK_DIR/count") == 3 ]]
grep -Fq 'mail-test' "$WORK_DIR/captures/3.body"
grep -Fq 'text/html' "$WORK_DIR/captures/3.args"

HOSTNAME=mail-test STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf"
[[ $(<"$WORK_DIR/count") == 4 ]]
grep -Fq '1 packages updated' "$WORK_DIR/captures/4.body"
grep -Fq 'text/html' "$WORK_DIR/captures/4.args"

cat > "$WORK_DIR/current-status.json" <<'JSON'
{"targets":[
  {"id":"guest:986","type":"lxc","name":"mail-test","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON
sed -i 's/EMAIL_NO_UPDATES="false"/EMAIL_NO_UPDATES="true"/' "$WORK_DIR/update.conf"
HOSTNAME=mail-test STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/current-status.json" "$WORK_DIR/update.conf"
[[ $(<"$WORK_DIR/count") == 5 ]]
grep -Fq 'No updates found during search' "$WORK_DIR/captures/5.body"

echo 'html mail tests: PASS'
