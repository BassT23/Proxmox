#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
chmod 0700 "$work"
LOCAL_FILES="$work"
STATUS_MODEL_FILE="$work/status.json"
source "$root/status-model.sh"
mkdir "$work/bin"
cat > "$work/bin/curl" <<'SH'
#!/bin/bash
set -euo pipefail
printf 'CALL %s\n' "$*" >> "$HEARTBEAT_CALLS"
cat >/dev/null
[[ "$FAIL_TRANSPORT" != true ]]
SH
chmod 0700 "$work/bin/curl"
export PATH="$work/bin:$PATH" HEARTBEAT_CALLS="$work/calls" FAIL_TRANSPORT=false
export UU_CHECK_JOB_EXECUTION=true UU_JOB_SOURCE=initial-inventory UU_SCHEDULED_CHECK=true
export UU_HEARTBEAT_URL="http://127.0.0.1:9876/health?success=true"
export UU_HEARTBEAT_TOKEN_FILE="$work/token"
printf %s 'fixture-only-protected-credential' >"$work/token"
chmod 0600 "$work/token"
cat >"$STATUS_MODEL_FILE" <<'JSON'
{"schema_version":1,"targets":[{"id":"host:node","reachable":true,"check_status":"updates_available","updates":{"available":2}},{"id":"external:server","reachable":true,"check_status":"ok","updates":{"available":0}}]}
JSON
assert_denied() {
  if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$STATUS_MODEL_FILE" 0; then
    echo "Expected heartbeat denial: $1" >&2; exit 1
  fi
}
STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$STATUS_MODEL_FILE" 0
UU_SCHEDULED_CHECK=false; assert_denied manual; UU_SCHEDULED_CHECK=true
UU_JOB_SOURCE=scheduler; assert_denied unsafe_source; UU_JOB_SOURCE=initial-inventory
UU_SINGLE_TARGET=true; assert_denied single_target; unset UU_SINGLE_TARGET
for code in 1 2 4; do
  if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE "$code" 0 "$STATUS_MODEL_FILE" 0; then exit 1; fi
  if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 "$code" "$STATUS_MODEL_FILE" 0; then exit 1; fi
done
if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$STATUS_MODEL_FILE" 69; then exit 1; fi
cp "$STATUS_MODEL_FILE" "$work/valid.json"
for status in not_checked stopped skipped offline error; do
  sed "s/\"check_status\":\"ok\"/\"check_status\":\"$status\"/" "$work/valid.json" > "$STATUS_MODEL_FILE"
  assert_denied "$status"
done
printf '{"schema_version":1,"targets":[]}\n' > "$STATUS_MODEL_FILE"
assert_denied empty
printf '{"schema_version":1,"targets":null}\n' > "$STATUS_MODEL_FILE"
assert_denied invalid
cp "$work/valid.json" "$STATUS_MODEL_FILE"
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT
[[ $(grep -c '^CALL ' "$work/calls") == 1 ]]
! grep -Fq 'fixture-only-protected-credential' "$work/calls"
unset UU_HEARTBEAT_URL
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT
[[ $(grep -c '^CALL ' "$work/calls") == 1 ]]
UU_HEARTBEAT_URL="http://127.0.0.1:9876/health?success=true"
chmod 0666 "$work/token"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT >/dev/null 2>&1; then exit 1; fi
chmod 0600 "$work/token"
export FAIL_TRANSPORT=true
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT >/dev/null 2>&1; then exit 1; fi
FAIL_TRANSPORT=false
UU_HEARTBEAT_URL="file:///etc/shadow"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT >/dev/null 2>&1; then exit 1; fi
cat > "$work/bin/mail" <<'SH'
#!/bin/bash
cat >/dev/null
exit 7
SH
chmod 0700 "$work/bin/mail"
cat > "$work/update.conf" <<'CONF'
EMAIL_DAILY_CHECK="true"
EMAIL_SINGLE_RUNS="true"
EMAIL_USER="root"
EMAIL_NO_UPDATES="false"
CONF
# A failed scheduled mail delivery MUST withhold the success heartbeat,
# without changing established operator/manual mail failure semantics.
UU_SCHEDULED_CHECK=true
if STATUS_MODEL_SEND_NOTIFICATION "$STATUS_MODEL_FILE" "$work/update.conf" >/dev/null 2>&1; then
  echo "Failed required scheduled mail was accepted" >&2; exit 1
fi
UU_SCHEDULED_CHECK=false
STATUS_MODEL_SEND_NOTIFICATION "$STATUS_MODEL_FILE" "$work/update.conf" >/dev/null 2>&1
UU_SCHEDULED_CHECK=true
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
s=(root/"ultimate-updater").read_text()
assert 'STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE "$check_result" "$external_result" "$STATUS_FILE" "$notification_result"' in s
assert 'STATUS_MODEL_SEND_SUCCESS_HEARTBEAT || true' in s
assert 'STATUS_MODEL_SEND_NOTIFICATION "$STATUS_FILE" "$LOCAL_FILES/update.conf" || notification_result=$?' in s
PY
echo "scheduled success heartbeat tests: PASS"
