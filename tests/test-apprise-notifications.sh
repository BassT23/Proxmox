#!/usr/bin/env bash
# shellcheck disable=SC2034 # Loop variable exists only to bound duplicate events.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/fake" "$WORK_DIR/config"
cat > "$WORK_DIR/fake/apprise.py" <<'PY'
import os
import time


class NotifyType:
    WARNING = "warning"
    INFO = "info"
    SUCCESS = "success"


class Apprise:
    def add(self, url):
        self.url = url
        return True

    def notify(self, body, title, notify_type):
        log = os.environ.get("FAKE_APPRISE_LOG")
        if log:
            with open(log, "a", encoding="utf-8") as output:
                output.write(self.url + "\n")
        if self.url in os.environ.get("FAKE_APPRISE_FAIL", "").split("\n"):
            return False
        if self.url in os.environ.get("FAKE_APPRISE_SLEEP", "").split("\n"):
            time.sleep(2)
        return True
PY

cat > "$WORK_DIR/status.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:00Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":2},"last_update":{"status":"unknown"}}
]}
JSON
cat > "$WORK_DIR/config/providers" <<'EOF'
# Provider URLs remain in this protected file only.
mock://provider-a
mock://provider-b?token=redacted%20value
EOF
chmod 600 "$WORK_DIR/config/providers"
chmod 700 "$WORK_DIR/config"

export LOCAL_FILES="$WORK_DIR"
export UU_APPRISE_HELPER="$ROOT_DIR/notification-apprise.py"
export UU_APPRISE_STATE_FILE="$WORK_DIR/state.json"
export UU_APPRISE_URLS_FILE="$WORK_DIR/config/missing"
export PYTHONPATH="$WORK_DIR/fake"
export FAKE_APPRISE_LOG="$WORK_DIR/delivery.log"
export DELIVERY_STATUS_FILE="$WORK_DIR/status.json"
: > "$WORK_DIR/delivery.log"

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"

# A missing provider file keeps the transport disabled and performs no work.
STATUS_MODEL_SEND_APPRISE "$WORK_DIR/status.json" check updates 'disabled' || exit 1
[[ ! -s "$WORK_DIR/delivery.log" ]]

export UU_APPRISE_URLS_FILE="$WORK_DIR/config/providers"
run_delivery() {
  set +e
  printf '%s\n' 'synthetic notification with <safe> content' |
    python3 "$ROOT_DIR/notification-apprise.py" check "$DELIVERY_STATUS_FILE" updates
  local result=$?
  set -e
  return "$result"
}

# Two providers are delivered independently; URLs and query secrets do not
# appear in the persisted state or the generic error stream.
run_delivery
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 2 ]]
if grep -Fq 'provider-a' "$WORK_DIR/state.json" ||
  grep -Fq 'redacted' "$WORK_DIR/state.json"; then
  echo 'provider URL leaked into dedup state' >&2
  exit 1
fi

# An identical event is suppressed for both already-delivered providers.
run_delivery
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 2 ]]

# A partial delivery retries only the provider which failed previously.
cat > "$WORK_DIR/partial.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:00Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":3},"last_update":{"status":"unknown"}}
]}
JSON
export DELIVERY_STATUS_FILE="$WORK_DIR/partial.json"
export FAKE_APPRISE_FAIL='mock://provider-b?token=redacted%20value'
if run_delivery; then
  echo 'failed provider unexpectedly delivered' >&2
  exit 1
fi
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 4 ]]
unset FAKE_APPRISE_FAIL
run_delivery
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 5 ]]
[[ $(tail -n 1 "$WORK_DIR/delivery.log") == 'mock://provider-b?token=redacted%20value' ]]

# Corrupt state is recoverable and does not permanently suppress delivery.
printf '%s' '{not-json' > "$WORK_DIR/state.json"
run_delivery
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 7 ]]

# Recovery is a distinct check event, while a duplicate concurrent event is
# still single-flight protected by the state lock.
cat > "$WORK_DIR/recovery.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:01Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"error","reachable":false,"updates":{"available":null},"error":{"code":"CHECK_FAILED","message":"offline"}}
]}
JSON
for attempt in 1 2 3 4 5; do
  printf '%s\n' 'recovery issue' |
    python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/recovery.json" issues &
done
wait
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 9 ]]

cat > "$WORK_DIR/current.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:02Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"ok","reachable":true,"updates":{"available":0}}
]}
JSON
printf '%s\n' 'recovered' |
  python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/current.json" current
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 11 ]]

# Provider timeouts are bounded and can only be shortened for a fixture.
printf '%s\n' 'mock://slow?token=hidden' > "$WORK_DIR/config/providers"
export FAKE_APPRISE_SLEEP='mock://slow?token=hidden'
export UU_APPRISE_PROVIDER_TIMEOUT=0.1
export UU_APPRISE_DELIVERY_BUDGET=0.2
started=$SECONDS
if printf '%s\n' 'slow' | python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/status.json" updates 2>"$WORK_DIR/error"; then
  echo 'timeout provider unexpectedly succeeded' >&2
  exit 1
fi
(( SECONDS - started < 3 ))
if grep -Eiq 'hidden|mock://|token' "$WORK_DIR/error"; then
  echo 'provider data leaked into timeout diagnostics' >&2
  exit 1
fi
unset FAKE_APPRISE_SLEEP UU_APPRISE_PROVIDER_TIMEOUT UU_APPRISE_DELIVERY_BUDGET

# State retention remains bounded.
python3 - "$WORK_DIR/state.json" <<'PY'
import json
import sys
import time

state = {f"old:{index}": {"updated_at": time.time(), "fingerprint": "x"}
         for index in range(1030)}
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(state, output)
PY
chmod 600 "$WORK_DIR/state.json"
printf '%s\n' 'mock://bounded' > "$WORK_DIR/config/providers"
printf '%s\n' 'bounded' |
  python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/status.json" updates
python3 - "$WORK_DIR/state.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    state = json.load(source)
assert len(state) <= 1024
PY

# Scheduled and manual paths use the existing status renderer, while email
# policy remains independent.  The fixture also includes an External target.
cat > "$WORK_DIR/config/providers" <<'EOF'
mock://provider-a
mock://provider-b?token=redacted%20value
EOF
chmod 600 "$WORK_DIR/config/providers"
cat > "$WORK_DIR/integration-status.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:03Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":2},"last_update":{"status":"success","exit_code":0,"pending_before":2}},
  {"id":"external:backup","type":"external","name":"backup","check_status":"error","reachable":false,"updates":{"available":null},"error":{"code":"CHECK_FAILED","message":"offline"}}
]}
JSON
cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="root"
EMAIL_SENDER="root"
EMAIL_DAILY_CHECK="false"
EMAIL_SINGLE_RUNS="false"
EMAIL_NO_UPDATES="false"
EMAIL_ONLY_SECURITY="false"
EMAIL_ONLY_ERROR="true"
EOF
mkdir -p "$WORK_DIR/bin"
cat > "$WORK_DIR/bin/mail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF
chmod 750 "$WORK_DIR/bin/mail"
export PATH="$WORK_DIR/bin:$PATH"
export UU_APPRISE_STATE_FILE="$WORK_DIR/integration-state.json"
export DELIVERY_STATUS_FILE="$WORK_DIR/integration-status.json"
export UU_JOB_SOURCE=scheduler
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/integration-status.json" "$WORK_DIR/update.conf"
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 15 ]]

unset UU_JOB_SOURCE
export UU_SINGLE_TARGET=true UU_SINGLE_TARGET_ID=118 UU_SINGLE_TARGET_KIND=target
STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/integration-status.json" "$WORK_DIR/update.conf"
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 17 ]]
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK_DIR/integration-status.json" "$WORK_DIR/update.conf"
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 19 ]]

# Provider failure is observable but never becomes a functional check error.
cat > "$WORK_DIR/failure-status.json" <<'JSON'
{"generated_at":"2026-10-20T10:00:04Z","targets":[
  {"id":"guest:118","type":"lxc","name":"fixture","check_status":"updates_available","reachable":true,"updates":{"available":4}}
]}
JSON
export UU_APPRISE_STATE_FILE="$WORK_DIR/failure-state.json"
export FAKE_APPRISE_FAIL='mock://provider-a
mock://provider-b?token=redacted%20value'
if ! STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/failure-status.json" "$WORK_DIR/update.conf"; then
  echo 'Apprise failure changed the functional check result' >&2
  exit 1
fi
unset FAKE_APPRISE_FAIL

# A remote worker handoff is not an additional notification authority.
export UU_REMOTE_NODE_HANDOFF=true
STATUS_MODEL_SEND_APPRISE "$WORK_DIR/integration-status.json" check issues 'remote handoff' || exit 1
[[ $(wc -l < "$WORK_DIR/delivery.log") -eq 21 ]]
unset UU_REMOTE_NODE_HANDOFF UU_SINGLE_TARGET UU_SINGLE_TARGET_ID UU_SINGLE_TARGET_KIND

# Symlink and mode violations fail closed without exposing the URL.
printf '%s\n' 'mock://secret-provider?token=hidden' > "$WORK_DIR/real-providers"
chmod 600 "$WORK_DIR/real-providers"
ln -s "$WORK_DIR/real-providers" "$WORK_DIR/symlink-providers"
export UU_APPRISE_URLS_FILE="$WORK_DIR/symlink-providers"
if printf '%s\n' 'unsafe' | python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/status.json" updates 2>"$WORK_DIR/symlink-error"; then
  echo 'provider symlink unexpectedly accepted' >&2
  exit 1
fi
if grep -Eiq 'secret|hidden|mock://' "$WORK_DIR/symlink-error"; then
  echo 'provider data leaked for symlink rejection' >&2
  exit 1
fi

export UU_APPRISE_URLS_FILE="$WORK_DIR/real-providers"
chmod 644 "$WORK_DIR/real-providers"
if printf '%s\n' 'unsafe' | python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/status.json" updates 2>"$WORK_DIR/mode-error"; then
  echo 'world-readable provider file unexpectedly accepted' >&2
  exit 1
fi

# The optional dependency is absent in this source-only environment; delivery
# fails generically and does not affect the caller's functional status.
chmod 600 "$WORK_DIR/real-providers"
unset PYTHONPATH
if printf '%s\n' 'missing dependency' |
  python3 "$ROOT_DIR/notification-apprise.py" check "$WORK_DIR/status.json" updates 2>"$WORK_DIR/dependency-error"; then
  echo 'missing Apprise dependency unexpectedly succeeded' >&2
  exit 1
fi
if grep -Eiq 'secret|hidden|mock://' "$WORK_DIR/dependency-error"; then
  echo 'provider data leaked for missing dependency' >&2
  exit 1
fi

printf '%s\n' 'apprise notification tests: PASS'
