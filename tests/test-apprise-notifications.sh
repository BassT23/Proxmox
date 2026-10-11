#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/apprise.py" <<'PY'
import os
import time
if os.environ.get('APPRISE_MISSING') == '1':
    raise ImportError('synthetic missing optional dependency')
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
        if os.environ.get("APPRISE_FAIL") == "1" or any(os.environ.get("APPRISE_FAIL_MATCH", "~~~") in url for url in self.urls):
            return False
        if any(os.environ.get("APPRISE_SLEEP_MATCH", "~~~") in url for url in self.urls):
            time.sleep(2)
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

# A remote cluster handoff may process status, but only the initiating node
# sends notifications. The remote process must never double-send them.
UU_REMOTE_NODE_HANDOFF=true UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ ! -e "$WORK/sent" ]]

# Apprise delivery is independent of disabled scheduled email.
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 2 ]]
[[ $(wc -l < "$WORK/python-invocations") -eq 1 ]]
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 2 ]]
grep -Fq 'check|info|1' "$WORK/sent"

# Clearing updates emits one recovery event (no duplicate current-state spam).
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["targets"][0]["check_status"]="ok";d["targets"][0]["updates"]["available"]=0;json.dump(d,open(p,"w"))
PY
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]
grep -Fq 'check|success|1' "$WORK/sent"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]

# Delivery failure must not advance the fingerprint.
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["targets"][0]["check_status"]="updates_available";d["targets"][0]["updates"]["available"]=1;json.dump(d,open(p,"w"))
PY
APPRISE_FAIL=1 UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/error"
[[ $(wc -l < "$WORK/sent") -eq 4 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/error"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 6 ]]

# Manual single-target update events also deliver independent of email policy.
export UU_SINGLE_TARGET=true UU_SINGLE_TARGET_ID=910 UU_SINGLE_TARGET_KIND=target
STATUS_MODEL_SEND_UPDATE_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" "2026-10-08T11:00:00Z"
[[ $(wc -l < "$WORK/sent") -eq 8 ]]
grep -Fq 'update|' "$WORK/sent"

# Provider configuration must be protected: group-readable config fails closed.
chmod 0644 "$WORK/urls"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/insecure"
[[ $(wc -l < "$WORK/sent") -eq 8 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/insecure"

# Provider URL configuration symlinks are refused without sending credentials.
chmod 0600 "$WORK/urls"
mv "$WORK/urls" "$WORK/real-urls"
ln -s "$WORK/real-urls" "$WORK/urls"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/url-link-error"
[[ $(wc -l < "$WORK/sent") -eq 8 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/url-link-error"
rm "$WORK/urls"
mv "$WORK/real-urls" "$WORK/urls"

# Disabled transport leaves native email alone (verified by separate existing test).
unset UU_APPRISE_URLS_FILE
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 8 ]]

# Partial delivery: the successful provider never receives a second copy on retry.
export UU_APPRISE_URLS_FILE="$WORK/urls"
chmod 0600 "$WORK/urls"
unset UU_SINGLE_TARGET UU_SINGLE_TARGET_ID
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['targets'][0]['updates']['available']=5;json.dump(d,open(p,'w'))
PY
APPRISE_FAIL_MATCH=gotifys UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/partial-error"
[[ $(wc -l < "$WORK/sent") -eq 9 ]]
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 10 ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/partial-error"

# Corrupted state must recover and resume delivery rather than mute notifications.
printf '{corrupt' > "$WORK/dedupe.json"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq 12 ]]

# Per-provider timeout is enforced without waiting for the default production bound.
python3 - "$ROOT/notification-apprise.py" "$WORK/urls" <<'PY'
import importlib.util,os,sys,time
spec=importlib.util.spec_from_file_location('notify',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.DELIVERY_TIMEOUT_SECONDS=0.25
os.environ['APPRISE_SLEEP_MATCH']='ntfys'
start=time.monotonic()
assert m.deliver_one('ntfys://fixture.example.invalid/channel','title','body','updates') is False
assert time.monotonic()-start < 1.5
os.environ.pop('APPRISE_SLEEP_MATCH',None)
assert m.deliver_one('gotifys://fixture.example.invalid/token?special=a%26b','title','body','updates') is True
now=time.time()
old={'stale':{'updated_at':now-31*86400}, 'fresh':{'updated_at':now, 'fingerprint':'x'}}
assert list(m.prune_delivery_state(old,now))==['fresh']
m.MAX_STATE_ENTRIES=2
assert len(m.prune_delivery_state({str(i):{'updated_at':now+i} for i in range(5)},now))<=2
import json,tempfile,pathlib
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d)/'state.json'
 p.write_text('{invalid',encoding='utf-8');p.chmod(0o600)
 assert m.read_delivery_state(p)=={}
 p.unlink();(pathlib.Path(d)/'actual').write_text('{}')
 p.symlink_to('actual')
 try: m.read_delivery_state(p)
 except OSError: pass
 else: raise AssertionError('symlink state was accepted')
 rows={'targets':[{'id':'guest:911','updates':{'available':0}}, {'id':'external:site-a','updates':{'available':2},'reboot_required':True}]}
 (pathlib.Path(d)/'status.json').write_text(json.dumps(rows))
 _,selected=m.read_status(pathlib.Path(d)/'status.json','external:site-a')
 assert len(selected)==1 and selected[0]['id']=='external:site-a' and selected[0]['reboot'] is True
print('Apprise provider timeout, dedupe retention, state safety, External and URL special characters: PASS')
PY

# Missing optional Apprise does not fail normal checks and never advances delivery state.
export UU_APPRISE_STATE_FILE="$WORK/missing-dependency.json"
python3 - "$WORK/status.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['targets'][0]['updates']['available']=6;json.dump(d,open(p,'w'))
PY
before=$(wc -l < "$WORK/sent")
APPRISE_MISSING=1 UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf" 2>"$WORK/missing-apprise-error"
[[ $(wc -l < "$WORK/sent") -eq "$before" ]]
! grep -Eiq '(ntfys|gotifys|token|fixture.example)' "$WORK/missing-apprise-error"
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq $((before + 2)) ]]

# Concurrent identical event processing has a shared state lock; send once per provider.
export UU_APPRISE_STATE_FILE="$WORK/concurrent.json"
before=$(wc -l < "$WORK/sent")
printf 'synthetic update notification\n' | python3 "$ROOT/notification-apprise.py" check "$WORK/status.json" updates &
first=$!
printf 'synthetic update notification\n' | python3 "$ROOT/notification-apprise.py" check "$WORK/status.json" updates &
second=$!
wait "$first"
wait "$second"
[[ $(wc -l < "$WORK/sent") -eq $((before + 2)) ]]

# Native mail and Apprise remain independent: a scheduled update alert may use both.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/mail" <<'EMAIL_FAKE'
#!/usr/bin/env bash
cat >/dev/null
printf 'mail-invoked\n' >> "$EMAIL_CAPTURE"
EMAIL_FAKE
chmod 0755 "$WORK/bin/mail"
export PATH="$WORK/bin:$PATH" EMAIL_CAPTURE="$WORK/mail-events"
sed -i 's/EMAIL_DAILY_CHECK="false"/EMAIL_DAILY_CHECK="true"/' "$WORK/update.conf"
export UU_APPRISE_STATE_FILE="$WORK/mail-and-apprise.json"
before=$(wc -l < "$WORK/sent")
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq $((before + 2)) ]]
[[ $(wc -l < "$WORK/mail-events") -eq 1 ]]

# Malformed per-provider bookkeeping must recover without muting all notifications.
export UU_APPRISE_STATE_FILE="$WORK/malformed-provider-state.json"
python3 - "$ROOT/notification-apprise.py" "$WORK/status.json" "$UU_APPRISE_STATE_FILE" <<'PY'
import hashlib,importlib.util,json,pathlib,sys,time
spec=importlib.util.spec_from_file_location("notification",sys.argv[1])
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
_,rows=mod.read_status(pathlib.Path(sys.argv[2]),"")
marker={"kind":"check","state":"updates","targets":rows}
fingerprint=hashlib.sha256(json.dumps(marker,sort_keys=True,default=str,separators=(",",":")).encode()).hexdigest()
p=pathlib.Path(sys.argv[3])
p.write_text(json.dumps({"check:all":{"fingerprint":fingerprint,"state":"updates",
    "updated_at":time.time(),"delivered_providers":42}}))
p.chmod(0o600)
PY
before=$(wc -l < "$WORK/sent")
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq $((before + 2)) ]]
UU_JOB_SOURCE=scheduler STATUS_MODEL_SEND_NOTIFICATION "$WORK/status.json" "$WORK/update.conf"
[[ $(wc -l < "$WORK/sent") -eq $((before + 2)) ]]

echo "Apprise notification integration tests: PASS"
