#!/usr/bin/env bash
# shellcheck disable=SC2034 # Loop variable only bounds concurrent attempts.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/config" "$WORK_DIR/state"
cat > "$WORK_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' call >> "${HEARTBEAT_CALLS:?}"
cat > "${HEARTBEAT_AUTH:?}"
exit "${FAKE_CURL_RC:-0}"
EOF
chmod 750 "$WORK_DIR/bin/curl"

RUN_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
cat > "$WORK_DIR/status.json" <<EOF
{"schema_version":1,"generated_at":"$RUN_STARTED_AT","targets":[
 {"id":"host:node1","type":"host","node":"node1","check_status":"ok","reachable":true,"updates":{"available":0},"last_check":"$RUN_STARTED_AT","package_data_invalidated":false,"package_mutation_in_progress":false},
 {"id":"101","type":"lxc","node":"node1","check_status":"updates_available","reachable":true,"updates":{"available":1},"last_check":"$RUN_STARTED_AT","package_data_invalidated":false,"package_mutation_in_progress":false},
 {"id":"102","type":"vm","node":"node1","check_status":"ok","reachable":true,"updates":{"available":0},"last_check":"$RUN_STARTED_AT","package_data_invalidated":false,"package_mutation_in_progress":false},
 {"id":"external:one","type":"external","node":null,"check_status":"ok","reachable":true,"updates":{"available":0},"last_check":"$RUN_STARTED_AT","package_data_invalidated":false,"package_mutation_in_progress":false}
]}
EOF
printf '%s\n' 'https://heartbeat.example.invalid/pulse' > "$WORK_DIR/config/url"
printf '%s\n' 'heartbeat-secret' > "$WORK_DIR/config/token"
chmod 600 "$WORK_DIR/config/url" "$WORK_DIR/config/token"
chmod 700 "$WORK_DIR/config" "$WORK_DIR/state"
: > "$WORK_DIR/calls"
: > "$WORK_DIR/auth"

export LOCAL_FILES="$WORK_DIR"
export STATUS_MODEL_FILE="$WORK_DIR/status.json"
export UU_CHECK_JOB_EXECUTION=true UU_SCHEDULED_CHECK=true UU_JOB_SOURCE=initial-inventory UU_GLOBAL_CHECK=true
export UU_SINGLE_TARGET=false UU_SINGLE_TARGET_CHECK=false UU_REMOTE_NODE_HANDOFF=false
export UU_HEARTBEAT_URL_FILE="$WORK_DIR/config/url"
export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/token"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/last"
export UU_APPRISE_URLS_FILE="$WORK_DIR/config/missing"
export HEARTBEAT_CALLS="$WORK_DIR/calls" HEARTBEAT_AUTH="$WORK_DIR/auth"
export PATH="$WORK_DIR/bin:$PATH"

# shellcheck disable=SC1091
source "$ROOT_DIR/status-model.sh"
grep -Fq 'STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE' "$ROOT_DIR/ultimate-updater"
grep -Fq 'STATUS_MODEL_SEND_SUCCESS_HEARTBEAT' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_HEARTBEAT_URL_FILE' "$ROOT_DIR/job-runner.sh"
grep -Fq -- '--connect-timeout 5' "$ROOT_DIR/status-model.sh"
grep -Fq -- '--max-time 20' "$ROOT_DIR/status-model.sh"
grep -Fq -- '--max-redirs 0' "$ROOT_DIR/status-model.sh"

STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$WORK_DIR/status.json" 0 "$RUN_STARTED_AT"
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT run-success
[[ $(wc -l < "$WORK_DIR/calls") -eq 1 ]]
grep -Fqx 'Authorization: Bearer heartbeat-secret' "$WORK_DIR/auth"
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT run-success
[[ $(wc -l < "$WORK_DIR/calls") -eq 1 ]]

# The real global CLI path uses the same combined notification result and
# invokes the heartbeat only after the read-only check and External phase.
cat > "$WORK_DIR/update.conf" <<'EOF'
EMAIL_USER="test-recipient"
EMAIL_SENDER="test-sender"
EMAIL_DAILY_CHECK="false"
EMAIL_SINGLE_RUNS="false"
EMAIL_NO_UPDATES="false"
EMAIL_ONLY_SECURITY="false"
EOF
cat > "$WORK_DIR/check-updates.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
python3 - "$WORK_DIR/status.json" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
timestamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
payload["generated_at"] = timestamp
for target in payload["targets"]:
    target["last_check"] = timestamp
    target["check_status"] = "updates_available" if target["id"] == "101" else "ok"
    target["reachable"] = True
    target["error"] = None
    target["skip_reason"] = None
json.dump(payload, open(path, "w", encoding="utf-8"))
PY
exit 0
EOF
chmod 750 "$WORK_DIR/check-updates.sh"
cat > "$WORK_DIR/bin/mail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 7
EOF
chmod 750 "$WORK_DIR/bin/mail"
rm -f "$WORK_DIR/calls" "$WORK_DIR/auth" "$WORK_DIR/state/cli" "$WORK_DIR/state/cli.lock"
: > "$WORK_DIR/calls"
: > "$WORK_DIR/auth"
export UU_LOCAL_FILES="$WORK_DIR" UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/cli"
"$ROOT_DIR/ultimate-updater" check >/dev/null 2>"$WORK_DIR/cli-success-error"
[[ $(wc -l < "$WORK_DIR/calls") -eq 1 ]]
grep -Fqx 'Authorization: Bearer heartbeat-secret' "$WORK_DIR/auth"

# Notification delivery errors do not change the functional global-check rc
# and therefore cannot become a false package/update failure.
sed 's/EMAIL_DAILY_CHECK="false"/EMAIL_DAILY_CHECK="true"/' \
  "$WORK_DIR/update.conf" > "$WORK_DIR/notification-failure.conf"
cp "$WORK_DIR/update.conf" "$WORK_DIR/update.conf.normal"
cp "$WORK_DIR/notification-failure.conf" "$WORK_DIR/update.conf"
rm -f "$WORK_DIR/calls" "$WORK_DIR/state/cli-failure" "$WORK_DIR/state/cli-failure.lock"
: > "$WORK_DIR/calls"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/cli-failure"
"$ROOT_DIR/ultimate-updater" check >/dev/null 2>"$WORK_DIR/cli-failure-error"
[[ ! -s "$WORK_DIR/calls" ]]
cp "$WORK_DIR/update.conf.normal" "$WORK_DIR/update.conf"

# Parallel invocations for one run are single-flight protected.
rm -f "$WORK_DIR/state/parallel" "$WORK_DIR/state/parallel.lock" "$WORK_DIR/calls" "$WORK_DIR/auth"
: > "$WORK_DIR/calls"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/parallel"
for attempt in 1 2 3 4 5; do
  STATUS_MODEL_SEND_SUCCESS_HEARTBEAT run-parallel &
done
wait
[[ $(wc -l < "$WORK_DIR/calls") -eq 1 ]]

# Missing endpoint is the disabled default and performs no state/network work.
rm -f "$WORK_DIR/calls" "$WORK_DIR/state/disabled" "$WORK_DIR/state/disabled.lock"
: > "$WORK_DIR/calls"
export UU_HEARTBEAT_URL_FILE="$WORK_DIR/config/missing"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/disabled"
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT disabled-run
[[ ! -s "$WORK_DIR/calls" && ! -e "$WORK_DIR/state/disabled" ]]
export UU_HEARTBEAT_URL_FILE="$WORK_DIR/config/url"

# Manual, selected-target, update, wrong-source, and remote-handoff contexts
# are all ineligible and never reach curl.
for context in manual selected update wrong-source remote; do
  rm -f "$WORK_DIR/calls"
  : > "$WORK_DIR/calls"
  export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/$context"
  case "$context" in
    manual) export UU_CHECK_JOB_EXECUTION=false UU_SINGLE_TARGET=false UU_REMOTE_NODE_HANDOFF=false ;;
    selected) export UU_CHECK_JOB_EXECUTION=true UU_SINGLE_TARGET=true UU_SINGLE_TARGET_CHECK=true UU_REMOTE_NODE_HANDOFF=false ;;
    update) export UU_CHECK_JOB_EXECUTION=true UU_SINGLE_TARGET=false UU_SINGLE_TARGET_CHECK=false UU_JOB_SOURCE=update UU_REMOTE_NODE_HANDOFF=false ;;
    wrong-source) export UU_CHECK_JOB_EXECUTION=true UU_SINGLE_TARGET=false UU_SINGLE_TARGET_CHECK=false UU_JOB_SOURCE=scheduler UU_REMOTE_NODE_HANDOFF=false ;;
    remote) export UU_CHECK_JOB_EXECUTION=true UU_SINGLE_TARGET=false UU_SINGLE_TARGET_CHECK=false UU_JOB_SOURCE=initial-inventory UU_REMOTE_NODE_HANDOFF=true ;;
  esac
  STATUS_MODEL_SEND_SUCCESS_HEARTBEAT "$context-run"
  [[ ! -s "$WORK_DIR/calls" ]]
done
export UU_CHECK_JOB_EXECUTION=true UU_SCHEDULED_CHECK=true UU_JOB_SOURCE=initial-inventory
export UU_SINGLE_TARGET=false UU_SINGLE_TARGET_CHECK=false UU_REMOTE_NODE_HANDOFF=false

# Failed collections, notification delivery, and non-success inventory states
# withhold the signal before any endpoint is contacted.
rm -f "$WORK_DIR/calls"
: > "$WORK_DIR/calls"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/negative"
if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 10 0 "$WORK_DIR/status.json" 0 "$RUN_STARTED_AT"; then exit 1; fi
if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$WORK_DIR/status.json" 69 "$RUN_STARTED_AT"; then exit 1; fi
cp "$WORK_DIR/status.json" "$WORK_DIR/status.base"
for bad_case in unreachable stopped paused unsupported error warning missing-count stale duplicate empty; do
  cp "$WORK_DIR/status.base" "$WORK_DIR/status.json"
  python3 - "$WORK_DIR/status.json" "$bad_case" <<'PY'
import json
import sys

path, bad_case = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
if bad_case == "unreachable":
    payload["targets"][0]["reachable"] = False
elif bad_case in {"stopped", "paused"}:
    payload["targets"][0]["check_status"] = "skipped"
    payload["targets"][0]["skip_reason"] = {"code": "STOPPED_READ_ONLY" if bad_case == "stopped" else "PAUSED_READ_ONLY"}
elif bad_case == "unsupported":
    payload["targets"][0]["check_status"] = "unsupported"
elif bad_case == "error":
    payload["targets"][0]["check_status"] = "error"
    payload["targets"][0]["error"] = {"code": "CHECK_FAILED"}
elif bad_case == "warning":
    payload["targets"][0]["reboot_required"] = True
elif bad_case == "missing-count":
    del payload["targets"][0]["updates"]["available"]
elif bad_case == "stale":
    payload["generated_at"] = "2020-01-01T00:00:00Z"
    for target in payload["targets"]:
        target["last_check"] = "2020-01-01T00:00:00Z"
elif bad_case == "duplicate":
    payload["targets"].append(dict(payload["targets"][0]))
elif bad_case == "empty":
    payload["targets"] = []
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output)
PY
  if STATUS_MODEL_SCHEDULED_HEARTBEAT_ELIGIBLE 0 0 "$WORK_DIR/status.json" 0 "$RUN_STARTED_AT"; then exit 1; fi
done
cp "$WORK_DIR/status.base" "$WORK_DIR/status.json"
[[ ! -s "$WORK_DIR/calls" ]]

# Endpoint, token, ownership/mode, and transport failures are fail-closed and
# never expose the configured secret or endpoint in diagnostics.
python3 - "$WORK_DIR/status.json" "$RUN_STARTED_AT" <<'PY'
import json
import sys

path, timestamp = sys.argv[1:]
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
for target in payload["targets"]:
    target["check_status"] = "ok"
    target["skip_reason"] = None
    target["last_check"] = timestamp
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output)
PY
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/invalid-url"
printf '%s\n' 'file:///not-allowed' > "$WORK_DIR/config/url"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT invalid-url 2>"$WORK_DIR/error"; then exit 1; fi
grep -Fq 'invalid' "$WORK_DIR/error"
if grep -Fq 'heartbeat-secret' "$WORK_DIR/error" || grep -Fq 'file:///not-allowed' "$WORK_DIR/error"; then exit 1; fi
printf '%s\n' 'https://heartbeat.example.invalid/pulse' > "$WORK_DIR/config/url"
ln -s token "$WORK_DIR/config/token-link"
export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/token-link"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT symlink-token 2>/dev/null; then exit 1; fi
export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/token"
chmod 644 "$WORK_DIR/config/token"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT unsafe-mode 2>/dev/null; then exit 1; fi
chmod 600 "$WORK_DIR/config/token"
export FAKE_CURL_RC=22 UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/transport"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT transport-failure 2>"$WORK_DIR/transport-error"; then exit 1; fi
grep -Fq 'unchanged' "$WORK_DIR/transport-error"
unset FAKE_CURL_RC

# A token path owned by another user is rejected without reading it.  On an
# unprivileged fixture runner /etc/passwd provides a stable wrong-owner file;
# root runners use an explicitly chowned temporary file.
if [[ "$EUID" -eq 0 ]]; then
  cp "$WORK_DIR/config/token" "$WORK_DIR/config/wrong-owner"
  chown 65534:65534 "$WORK_DIR/config/wrong-owner"
  chmod 600 "$WORK_DIR/config/wrong-owner"
  export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/wrong-owner"
else
  export UU_HEARTBEAT_TOKEN_FILE=/etc/passwd
fi
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/wrong-owner"
if STATUS_MODEL_SEND_SUCCESS_HEARTBEAT wrong-owner 2>/dev/null; then exit 1; fi
export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/token"

# A configured email failure and a configured Apprise failure both withhold
# the heartbeat, while their failures remain separate from the check result.
sed 's/EMAIL_DAILY_CHECK="false"/EMAIL_DAILY_CHECK="true"/' \
  "$WORK_DIR/update.conf" > "$WORK_DIR/scheduled-update.conf"
cat > "$WORK_DIR/bin/mail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 7
EOF
chmod 750 "$WORK_DIR/bin/mail"
export UU_HEARTBEAT_TOKEN_FILE="$WORK_DIR/config/token"
export PATH="$WORK_DIR/bin:$PATH"
if STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/scheduled-update.conf" \
  >/dev/null 2>"$WORK_DIR/notification-email-error"; then exit 1; fi

# Successful email and Apprise delivery share one final heartbeat decision.
cat > "$WORK_DIR/bin/mail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
exit 0
EOF
chmod 750 "$WORK_DIR/bin/mail"
cat > "$WORK_DIR/successful-apprise" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$WORK_DIR/successful-apprise"
export UU_APPRISE_HELPER="$WORK_DIR/successful-apprise"
if ! STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/scheduled-update.conf" \
  >/dev/null 2>"$WORK_DIR/notification-combined-error"; then exit 1; fi
rm -f "$WORK_DIR/calls" "$WORK_DIR/state/combined" "$WORK_DIR/state/combined.lock"
: > "$WORK_DIR/calls"
export UU_HEARTBEAT_STATE_FILE="$WORK_DIR/state/combined"
STATUS_MODEL_SEND_SUCCESS_HEARTBEAT combined-run
[[ $(wc -l < "$WORK_DIR/calls") -eq 1 ]]

cat > "$WORK_DIR/failing-apprise" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 750 "$WORK_DIR/failing-apprise"
printf '%s\n' 'mock://configured-provider' > "$WORK_DIR/config/providers"
chmod 600 "$WORK_DIR/config/providers"
export UU_APPRISE_URLS_FILE="$WORK_DIR/config/providers"
export UU_APPRISE_HELPER="$WORK_DIR/failing-apprise" UU_APPRISE_PYTHON=/bin/bash
if STATUS_MODEL_SEND_NOTIFICATION "$WORK_DIR/status.json" "$WORK_DIR/update.conf" \
  >/dev/null 2>"$WORK_DIR/notification-apprise-error"; then exit 1; fi

echo 'scheduled success heartbeat tests: PASS'
