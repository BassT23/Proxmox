#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/captures"

# ---------------------------------------------------------------------------
# Mock: mail
# ---------------------------------------------------------------------------

printf '0\n' > "$WORK_DIR/count"

cat > "$WORK_DIR/mail" <<'EOF'
#!/bin/bash
set -euo pipefail

count=$(<"$MAIL_COUNTER")
count=$((count + 1))

printf '%s\n' "$count" > "$MAIL_COUNTER"
printf '%s\n' "$*" > "$MAIL_CAPTURE_DIR/$count.args"
cat > "$MAIL_CAPTURE_DIR/$count.body"
if [[ "${MAIL_FAIL_HTML:-false}" == true && "$*" == *"text/html"* ]]; then
  exit 7
fi
if [[ "${MAIL_FAIL:-false}" == true ]]; then
  exit 7
fi
EOF

chmod +x "$WORK_DIR/mail"

# ---------------------------------------------------------------------------
# Mock: sendmail
# ---------------------------------------------------------------------------

printf '0\n' > "$WORK_DIR/sendmail-count"

cat > "$WORK_DIR/sendmail" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count=$(<"$SENDMAIL_COUNTER")
count=$((count + 1))

printf '%s\n' "$count" > "$SENDMAIL_COUNTER"
printf '%s\n' "$*" > "$SENDMAIL_CAPTURE_DIR/$count.args"
cat > "$SENDMAIL_CAPTURE_DIR/$count.message"

if [[ "${SENDMAIL_FAIL:-false}" == true ]]; then
  exit 75
fi
EOF

chmod +x "$WORK_DIR/sendmail"

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

export LOCAL_FILES="$WORK_DIR"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
export PATH="$WORK_DIR:$PATH"

export MAIL_COUNTER="$WORK_DIR/count"
export MAIL_CAPTURE_DIR="$WORK_DIR/captures"

export SENDMAIL_COUNTER="$WORK_DIR/sendmail-count"
export SENDMAIL_CAPTURE_DIR="$WORK_DIR/captures"

# Isolated PATH for testing a host without sendmail, while retaining the
# commands needed by the multipart builder and the legacy mail(1) fallback.
mkdir -p "$WORK_DIR/no-sendmail"
for command_name in mail python3 mktemp chmod cat rm; do
  command_path=$(command -v "$command_name")
  ln -s "$command_path" "$WORK_DIR/no-sendmail/$command_name"
done

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

# ---------------------------------------------------------------------------
# Common test data
# ---------------------------------------------------------------------------

long_line=$(printf 'x%.0s' {1..400})
quoted_line=$(printf '%s %s' '"VM Name"' "'quoted'")
ansi_line=$(printf '\033[1;92mANSI-MARKER\033[0m')
osc_line=$(printf 'before\033]0;ignored-title\007after')

body=$(printf '%s\n' \
  '<node>' \
  'A&B' \
  "$quoted_line" \
  "$ansi_line" \
  "$osc_line" \
  '' \
  '  indented line' \
  'Umlaute: äöü 😀' \
  "$long_line")

# ---------------------------------------------------------------------------
# HTML mail tests
# ---------------------------------------------------------------------------

printf '%s\n' "$body" |
  STATUS_MODEL_SEND_HTML_MAIL \
    'Subject' \
    'sender@example.test' \
    'recipient@example.test'

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

python3 - "$WORK_DIR/captures/1.body" <<'PY'
import sys

body = open(sys.argv[1], encoding="utf-8").read()

assert "\x1b" not in body, "ANSI escape remained in HTML mail"
assert "[1;92m" not in body and "[0m" not in body, "ANSI parameters remained in HTML mail"
assert "ANSI-MARKER" in body, "normal text was lost during ANSI cleanup"
assert "beforeafter" in body, "OSC sequence was not removed"
assert "ignored-title" not in body, "OSC payload leaked into HTML mail"
PY

# Header values must not accept embedded line breaks.
if printf '%s\n' 'body' |
  STATUS_MODEL_SEND_HTML_MAIL \
    $'bad\nX-Injected: yes' \
    sender@example.test \
    recipient@example.test; then
  echo 'header injection was accepted' >&2
  exit 1
fi

[[ $(<"$WORK_DIR/count") == 1 ]]

# Empty HTML body.
: | STATUS_MODEL_SEND_HTML_MAIL \
  'Empty' \
  sender@example.test \
  recipient@example.test

[[ $(<"$WORK_DIR/count") == 2 ]]
grep -Fq '&nbsp;' "$WORK_DIR/captures/2.body"

# ---------------------------------------------------------------------------
# Multipart mail tests
# ---------------------------------------------------------------------------

multipart_body=$(printf '%s\n' \
  '<node>' \
  'A&B' \
  "$quoted_line" \
  "$ansi_line" \
  "$osc_line" \
  '' \
  '  indented line' \
  'Umlaute: äöü 😀' \
  "$long_line")

# Plain text first, HTML second.
printf '%s\n' "$multipart_body" |
  STATUS_MODEL_SEND_MULTIPART_MAIL \
    'Multipart Subject' \
    'sender@example.test' \
    'recipient@example.test'

[[ $(<"$WORK_DIR/sendmail-count") == 1 ]]
[[ $(<"$WORK_DIR/count") == 2 ]]

grep -Fq -- '-t -i -f sender@example.test' "$WORK_DIR/captures/1.args"

python3 - "$WORK_DIR/captures/1.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

# Message headers.
assert message["From"] == "sender@example.test"
assert message["To"] == "recipient@example.test"
assert message["Subject"] == "Multipart Subject"

# MIME structure and order.
assert message.get_content_type() == "multipart/alternative"

parts = message.get_payload()
assert len(parts) == 2, f"expected 2 MIME parts, got {len(parts)}"

plain, html = parts

assert plain.get_content_type() == "text/plain"
assert html.get_content_type() == "text/html"

assert plain.get_content_charset() == "utf-8"
assert html.get_content_charset() == "utf-8"

assert plain["Content-Transfer-Encoding"] == "8bit"
assert html["Content-Transfer-Encoding"] == "8bit"

plain_body = plain.get_content()
html_body = html.get_content()

# Plain text content.
assert "<node>" in plain_body
assert "A&B" in plain_body
assert '"VM Name"' in plain_body
assert "'quoted'" in plain_body
assert "Umlaute: äöü 😀" in plain_body
assert "  indented line" in plain_body
assert "ANSI-MARKER" in plain_body
assert "beforeafter" in plain_body
assert "\x1b" not in plain_body
assert "ignored-title" not in plain_body

# HTML content and escaping.
assert "&lt;node&gt;" in html_body
assert "A&amp;B" in html_body
assert "&quot;VM Name&quot;" in html_body
assert "&#x27;quoted&#x27;" in html_body
assert "Umlaute: äöü 😀" in html_body
assert "  indented line" in html_body
assert "&nbsp;" in html_body
assert "ANSI-MARKER" in html_body
assert "beforeafter" in html_body
assert "\x1b" not in html_body
assert "ignored-title" not in html_body
assert "<node>" not in html_body
PY

# Header injection must be rejected before sendmail is called.
assert_multipart_header_rejected() {
  local field="$1"
  shift

  if printf '%s\n' 'body' |
    STATUS_MODEL_SEND_MULTIPART_MAIL "$@"; then
    echo "multipart header injection was accepted in $field" >&2
    exit 1
  fi

  [[ $(<"$WORK_DIR/sendmail-count") == 1 ]]
}

assert_multipart_header_rejected \
  subject \
  $'bad\nX-Injected: yes' \
  sender@example.test \
  recipient@example.test

assert_multipart_header_rejected \
  sender \
  Subject \
  $'bad\nX-Injected: yes' \
  recipient@example.test

assert_multipart_header_rejected \
  recipient \
  Subject \
  sender@example.test \
  $'bad\nX-Injected: yes'

# Empty body must still produce a valid multipart message.
: | STATUS_MODEL_SEND_MULTIPART_MAIL \
  'Empty Multipart' \
  sender@example.test \
  recipient@example.test

[[ $(<"$WORK_DIR/sendmail-count") == 2 ]]

python3 - "$WORK_DIR/captures/2.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

assert message.get_content_type() == "multipart/alternative"

plain, html = message.get_payload()

assert plain.get_content_type() == "text/plain"
assert html.get_content_type() == "text/html"

assert plain.get_content_charset() == "utf-8"
assert html.get_content_charset() == "utf-8"

assert plain["Content-Transfer-Encoding"] == "8bit"
assert html["Content-Transfer-Encoding"] == "8bit"

assert "&nbsp;" in html.get_content()
PY

# If sendmail is unavailable, the existing mail(1) HTML path is used.
printf '%s\n' 'missing sendmail fallback' |
  PATH="$WORK_DIR/no-sendmail" STATUS_MODEL_SEND_MULTIPART_MAIL \
    'Missing Sendmail' \
    sender@example.test \
    recipient@example.test

[[ $(<"$WORK_DIR/sendmail-count") == 2 ]]
[[ $(<"$WORK_DIR/count") == 3 ]]
grep -Fq 'Content-Type: text/html; charset=UTF-8' "$WORK_DIR/captures/3.args"
grep -Fq 'missing sendmail fallback' "$WORK_DIR/captures/3.body"

# If mail(1) rejects HTML, retry through its existing plaintext path.
printf '%s\n' 'plaintext fallback' |
  MAIL_FAIL_HTML=true PATH="$WORK_DIR/no-sendmail" STATUS_MODEL_SEND_MULTIPART_MAIL \
    'Plaintext Fallback' \
    sender@example.test \
    recipient@example.test

[[ $(<"$WORK_DIR/sendmail-count") == 2 ]]
[[ $(<"$WORK_DIR/count") == 5 ]]
grep -Fq 'Content-Type: text/html; charset=UTF-8' "$WORK_DIR/captures/4.args"
grep -Fq 'Content-Type: text/plain; charset=UTF-8' "$WORK_DIR/captures/5.args"
grep -Fq 'plaintext fallback' "$WORK_DIR/captures/5.body"

# A sendmail delivery error also falls back to the existing mail(1) path.
printf '%s\n' 'failed sendmail fallback' |
  SENDMAIL_FAIL=true STATUS_MODEL_SEND_MULTIPART_MAIL \
    'Failure Test' \
    sender@example.test \
    recipient@example.test

[[ $(<"$WORK_DIR/sendmail-count") == 3 ]]
[[ $(<"$WORK_DIR/count") == 6 ]]
grep -Fq 'Content-Type: text/html; charset=UTF-8' "$WORK_DIR/captures/6.args"
grep -Fq 'failed sendmail fallback' "$WORK_DIR/captures/6.body"

# ---------------------------------------------------------------------------
# Notification tests
# ---------------------------------------------------------------------------

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

HOSTNAME=mail-test STATUS_MODEL_SEND_NOTIFICATION \
  "$WORK_DIR/status.json" "$WORK_DIR/update.conf"

[[ $(<"$WORK_DIR/sendmail-count") == 4 ]]

python3 - "$WORK_DIR/captures/4.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

assert message.get_content_type() == "multipart/alternative"
plain, html = message.get_payload()

assert "mail-test" in plain.get_content()
assert "mail-test" in html.get_content()
PY

HOSTNAME=mail-test STATUS_MODEL_SEND_UPDATE_NOTIFICATION \
  "$WORK_DIR/status.json" "$WORK_DIR/update.conf"

[[ $(<"$WORK_DIR/sendmail-count") == 5 ]]

python3 - "$WORK_DIR/captures/5.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

assert message.get_content_type() == "multipart/alternative"
plain, html = message.get_payload()

assert "1 packages updated" in plain.get_content()
assert "1 packages updated" in html.get_content()
PY

# No-updates notification.
cat > "$WORK_DIR/current-status.json" <<'JSON'
{"targets":[
  {"id":"guest:986","type":"lxc","name":"mail-test","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON

sed -i 's/EMAIL_NO_UPDATES="false"/EMAIL_NO_UPDATES="true"/' "$WORK_DIR/update.conf"

HOSTNAME=mail-test STATUS_MODEL_SEND_NOTIFICATION \
  "$WORK_DIR/current-status.json" "$WORK_DIR/update.conf"

[[ $(<"$WORK_DIR/sendmail-count") == 6 ]]

python3 - "$WORK_DIR/captures/6.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

assert message.get_content_type() == "multipart/alternative"
plain, html = message.get_payload()

assert "No updates found during search" in plain.get_content()
assert "No updates found during search" in html.get_content()
PY

# ---------------------------------------------------------------------------
# Plain text mail tests
# ---------------------------------------------------------------------------

plain_line=$(printf '\033[1;33mPLAIN-ANSI-MARKER\033[0m')

printf '%s\n' "$plain_line" |
  STATUS_MODEL_SEND_TEXT_MAIL \
    'Plain subject' \
    'sender@example.test' \
    'recipient@example.test'

[[ $(<"$WORK_DIR/count") == 7 ]]

python3 - "$WORK_DIR/captures/7.body" <<'PY'
import sys

body = open(sys.argv[1], encoding="utf-8").read()

assert "\x1b" not in body, "ANSI escape remained in plaintext mail"
assert "[1;33m" not in body and "[0m" not in body, "ANSI parameters remained in plaintext mail"
assert "PLAIN-ANSI-MARKER" in body
PY

if printf '%s\n' 'body' |
  STATUS_MODEL_SEND_TEXT_MAIL \
    $'bad\nX-Injected: yes' \
    sender@example.test \
    recipient@example.test; then
  echo 'plaintext header injection was accepted' >&2
  exit 1
fi

[[ $(<"$WORK_DIR/count") == 7 ]]

# ---------------------------------------------------------------------------
# ANSI status notification test
# ---------------------------------------------------------------------------

python3 - "$WORK_DIR/ansi-status.json" <<'PY'
import json
import sys

payload = {"targets": [{
    "id": "guest:987",
    "type": "lxc",
    "name": "ansi-status",
    "check_status": "error",
    "reachable": True,
    "updates": {"available": None},
    "error": {
        "code": "CHECK_FAILED",
        "message": "before\x1b]0;ignored-title\x07\x1b[1;91mSTATUS-ANSI-MARKER\x1b[0mafter",
    },
}]}

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(payload, output)
PY

HOSTNAME=mail-test STATUS_MODEL_SEND_NOTIFICATION \
  "$WORK_DIR/ansi-status.json" "$WORK_DIR/update.conf"

[[ $(<"$WORK_DIR/sendmail-count") == 7 ]]

python3 - "$WORK_DIR/captures/7.message" <<'PY'
import sys
from email import policy
from email.parser import BytesParser

with open(sys.argv[1], "rb") as source:
    message = BytesParser(policy=policy.default).parse(source)

plain, html = message.get_payload()

for body in (plain.get_content(), html.get_content()):
    assert "\x1b" not in body
    assert "STATUS-ANSI-MARKER" in body
    assert "ignored-title" not in body
PY

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

echo 'html mail tests: PASS'
