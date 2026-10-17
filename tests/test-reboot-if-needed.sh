#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Extract only the production decision functions.  The fixture never sources
# update.sh's command runner and never invokes qm, pct, systemd, or a guest.
awk '/^UPDATE_REBOOT_STATUS_FRESH\(\) \{/{copy=1} copy{print} /^\}\n?$/{if(copy && seen++){exit}} /^AUTO_REBOOT_GUEST\(\) \{/{seen=0}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/reboot-functions.sh"

cat > "$WORK_DIR/harness.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$1"
STATUS_MODEL_FILE="$2/status.json"
UPDATE_RUN_STARTED_AT=2026-10-17T10:00:00Z
REBOOT_IF_NEEDED=true
REBOOT_CALLS="$2/reboots"
FAILURE_FILE="$2/reboot-failure"
: > "$REBOOT_CALLS"
RUN_PROXMOX_COMMAND() { printf '%s\n' "$*" >> "$REBOOT_CALLS"; return "${REBOOT_RC:-0}"; }
ERROR() { return 0; }
STATUS_MODEL_REBOOT_FAILURE() { printf '%s\n' "$*" >> "$FAILURE_FILE"; }

write_status() {
  local status="$1" timestamp="$2" reboot_required="$3"
  cat > "$STATUS_MODEL_FILE" <<JSON
{"targets":[{"id":"986","last_update":{"status":"$status","timestamp":"$timestamp","reboot_required":$reboot_required}}]}
JSON
}

# A fresh successful update may request exactly one supported guest reboot.
write_status success 2026-10-17T10:01:00Z true
AUTO_REBOOT_GUEST vm 986 false
[[ "$(cat "$REBOOT_CALLS")" == 'qm reboot 986' ]]

# API updates are denied even when the global setting is true.
: > "$REBOOT_CALLS"
UU_API_ACTION=update AUTO_REBOOT_GUEST vm 986 false
[[ ! -s "$REBOOT_CALLS" ]]
unset UU_API_ACTION

# Disabled, stale, failed, unknown, and originally stopped cases do not reboot.
for mode in disabled stale failed unknown stopped; do
  : > "$REBOOT_CALLS"
  case "$mode" in
    disabled) REBOOT_IF_NEEDED=false; write_status success 2026-10-17T10:01:00Z true; AUTO_REBOOT_GUEST vm 986 false; REBOOT_IF_NEEDED=true ;;
    stale) write_status success 2026-10-17T09:59:00Z true; AUTO_REBOOT_GUEST vm 986 false ;;
    failed) write_status failed 2026-10-17T10:01:00Z true; AUTO_REBOOT_GUEST vm 986 false ;;
    unknown) write_status success 2026-10-17T10:01:00Z false; AUTO_REBOOT_GUEST vm 986 false ;;
    stopped) write_status success 2026-10-17T10:01:00Z true; AUTO_REBOOT_GUEST vm 986 true ;;
  esac
  [[ ! -s "$REBOOT_CALLS" ]]
done

# A failed controlled reboot is not silently reported as a successful update.
write_status success 2026-10-17T10:01:00Z true
: > "$REBOOT_CALLS"
set +e
REBOOT_RC=7 AUTO_REBOOT_GUEST lxc 986 false
rc=$?
set -e
[[ $rc -eq 7 ]]
[[ "$(cat "$REBOOT_CALLS")" == 'pct reboot 986' ]]

printf 'reboot-if-needed decision tests: PASS\n'
EOF
chmod 750 "$WORK_DIR/harness.sh"

bash "$WORK_DIR/harness.sh" "$WORK_DIR/reboot-functions.sh" "$WORK_DIR"
grep -Fq 'REBOOT_IF_NEEDED="false"' "$ROOT_DIR/update.conf.dist"
grep -Fq 'UU_API_REBOOT_ALLOWED=false' "$ROOT_DIR/update.sh"
grep -Fq 'REBOOT_CONFIRMATION_REQUIRED' "$ROOT_DIR/web-ui/server.py"

echo 'reboot-if-needed policy tests: PASS'
