#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/apprise.py" <<'PY'
import os
class NotifyType:
    WARNING="warning"
    INFO="info"
    SUCCESS="success"
class Apprise:
    def __init__(self):
        self.urls=[]
    def add(self, url):
        self.urls.append(url)
        return True
    def notify(self, body, title, notify_type):
        if os.environ.get("APPRISE_FAIL") == "1":
            return False
        with open(os.environ["APPRISE_CAPTURE"], "a", encoding="utf-8") as dest:
            dest.write(title + "|" + notify_type + "|" + str(len(self.urls)) + "\n")
        return True
PY
cat > "$WORK/status.json" <<'JSON'
{"schema_version":1,"generated_at":"2026-10-08T12:00:00Z","targets":[{"id":"guest:910","type":"lxc","name":"debian","node":"test","check_status":"updates_available","reachable":true,"updates":{"available":2},"normal_updates":2,"security_updates":0,"reboot_required":false}]}
JSON
cat > "$WORK/update.conf" <<'EOF'
EMAIL_USER="dummy"
EMAIL_SENDER="dummy"
EMAIL_NO_UPDATES="false"
EMAIL_ONLY_SECURITY="false"
EMAIL_ONLY_ERROR="false"
EMAIL_SINGLE_RUNS="false"
EMAIL_DAILY_CHECK="false"
EOF
cat > "$WORK/urls" <<'EOF'
ntfys://fixture.example.invalid/channel
gotifys://fixture.example.invalid/token
EOF
chmod 0600 "$WORK/urls"
export UU_APPRISE_URLS_FILE="$WORK/urls"
export UU_APPRISE_STATE_FILE="$WORK/dedupe.json"
export UU_APPRISE_HELPER="$ROOT/notification-apprise.py"
export APPRISE_CAPTURE="$WORK/sent"
export PYTHONPATH="$WORK${PYTHONPATH:+:$PYTHONPATH}"
# Optional dedicated Python runtime must be honored without replacing system Python.
cat > "$WORK/apprise-python" <<'WRAPPER'
#!/usr/bin/env bash
printf 'invoked\n' >> "${APPRISE_PYTHON_CAPTURE:?}"
exec python3 "$@"
WRAPPER
chmod 0755 "$WORK/apprise-python"
export UU_APPRISE_PYTHON="$WORK/apprise-python" APPRISE_PYTHON_CAPTURE="$WORK/python-invocations"
export LOCAL_FILES="$WORK" STATUS_MODEL_FILE="$WORK/status.json" HOSTNAME=Test-Cluster
# shellcheck disable=SC1091
source "$ROOT/status-model.sh"

# Apprise delivery is independent of disabled scheduled email.
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 1 ]]
[[ $(wc -l < "$WORK/python-invocations") -eq 1 ]]
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 1 ]]
grep -Fq 'check|info|2' "$WORK/sent"

# Clearing updates emits one recovery event (no duplicate current-state spam).
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["targets"][0]["check_status"]="ok";d["targets"][0]["updates"]["available"]=0;json.dump(d,open(p,"w"))
PY
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 2 ]]
grep -Fq 'check|success|2' "$WORK/sent"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 2 ]]

# Delivery failure must not advance the fingerprint.
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["targets"][0]["check_status"]="updates_available";d["targets"][0]["updates"]["available"]=1;json.dump(d,open(p,"w"))
PY
APPRISE_FAIL=1 UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/error"
[[ $(wc -l < "$WORK/sent") -eq 2 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/error"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 3 ]]

# Manual single-target update events also deliver independent of email policy.
export UU_SINGLE_TARGET=true UU_SINGLE_TARGET_ID=910 UU_SINGLE_TARGET_KIND=target
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" "2026-10-08T11:00:00Z"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]
grep -Fq 'update|' "$WORK/sent"

# Provider configuration must be protected: group-readable config fails closed.
chmod 0644 "$WORK/urls"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/insecure"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/insecure"

# Disabled transport leaves native email alone (verified by separate existing test).
unset UU_APPRISE_URLS_FILE
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]

echo "Apprise notification integration tests: PASS"
