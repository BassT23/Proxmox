#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
export WORK_DIR
trap 'rm -rf -- "$WORK_DIR"' EXIT

sed -n '/^CAPTURE_POST_UPDATE_STATUS() {/,/^}/p' "$ROOT_DIR/update.sh" > "$WORK_DIR/capture.sh"
cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$WORK_DIR/check.sh"

LOCAL_FILES="$WORK_DIR/local"
TEMP_STATE_DIR="$LOCAL_FILES/temp"
UU_REMOTE_WORK_DIR="$WORK_DIR/remote"
CHECK_SCRIPT="$WORK_DIR/check.sh"
UU_POST_UPDATE_STATUS_CAPTURE=true
UU_REMOTE_DEFER_STATUS_FINISH=true
export LOCAL_FILES TEMP_STATE_DIR UU_REMOTE_WORK_DIR CHECK_SCRIPT UU_POST_UPDATE_STATUS_CAPTURE UU_REMOTE_DEFER_STATUS_FINISH
mkdir -p "$TEMP_STATE_DIR"
cp "$ROOT_DIR/status-model.sh" "$LOCAL_FILES/status-model.sh"
cat > "$WORK_DIR/check-status.json" <<'EOF'
{"schema_version":1,"targets":[{"id":"191","type":"lxc","transport":"pct","reachable":true,"os":"ubuntu","updates":{"available":0},"reboot_required":false,"check_status":"ok","error":null}]}
EOF
cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$UU_REMOTE_DEFER_STATUS_FINISH" > "$WORK_DIR/defer-value"
printf '%s\n' "$STATUS_MODEL_SCRIPT" > "$WORK_DIR/status-script"
. "$STATUS_MODEL_SCRIPT"
STATUS_MODEL_INIT
STATUS_MODEL_RECORD 191 lxc pct true ubuntu ubuntu 0 false ok "" "" node3 Testing-2
STATUS_MODEL_FINISH
exit 0
EOF
chmod 750 "$WORK_DIR/check.sh"
source "$ROOT_DIR/status-model.sh"
# shellcheck disable=SC1091
source "$WORK_DIR/capture.sh"
CAPTURE_POST_UPDATE_STATUS 191 ccontainer
test -s "$UU_REMOTE_WORK_DIR/post-update-status.rc"
test ! -e "$TEMP_STATE_DIR/post-update-status.rc"
grep -Fxq 0 "$UU_REMOTE_WORK_DIR/post-update-status.rc"
grep -Fxq false "$WORK_DIR/defer-value"
grep -Fxq "$LOCAL_FILES/status-model.sh" "$WORK_DIR/status-script"
grep -Fq 'UU_EXPLICIT_TARGET_CHECK=true' "$ROOT_DIR/update.sh"
grep -Fq 'STATUS_MODEL_SCRIPT="$LOCAL_FILES/status-model.sh"' "$ROOT_DIR/update.sh"
grep -Fq 'UU_REMOTE_DEFER_STATUS_FINISH=false TAG_OUTPUT=false' "$ROOT_DIR/update.sh"

# A successful helper with a not_checked record is not a successful capture.
sed 's/"check_status":"ok"/"check_status":"not_checked"/' "$WORK_DIR/check-status.json" > "$WORK_DIR/check-status-not-checked.json"
cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
cp "$WORK_DIR/check-status-not-checked.json" "$LOCAL_FILES/status.json"
exit 0
EOF
chmod 750 "$WORK_DIR/check.sh"
CAPTURE_POST_UPDATE_STATUS 191 ccontainer 2>"$WORK_DIR/not-checked-error"
grep -Fq 'POST_UPDATE_CAPTURE_NOT_CHECKED' "$WORK_DIR/not-checked-error"
grep -Fxq 89 "$UU_REMOTE_WORK_DIR/post-update-status.rc"

chmod 640 "$CHECK_SCRIPT"
CAPTURE_POST_UPDATE_STATUS 191 ccontainer 2>"$WORK_DIR/capture-error"
grep -Fq 'POST_UPDATE_CAPTURE_HELPER_NOT_EXECUTABLE' "$WORK_DIR/capture-error"
grep -Fxq 127 "$UU_REMOTE_WORK_DIR/post-update-status.rc"
echo 'post-update capture workspace path: PASS'
