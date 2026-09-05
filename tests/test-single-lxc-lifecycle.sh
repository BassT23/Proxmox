#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/pct" <<'EOF'
#!/bin/bash
case "${1:-}" in
  status) cat "$PCT_STATE" ;;
  config) printf 'ostype: debian\nhostname: fixture\n' ;;
  start) printf 'status: running\n' > "$PCT_STATE"; printf 'start\n' >> "$PCT_CALLS" ;;
  shutdown) printf 'status: stopped\n' > "$PCT_STATE"; printf 'shutdown\n' >> "$PCT_CALLS" ;;
  *) exit 0 ;;
esac
EOF
chmod 750 "$WORK_DIR/pct"

sed -n '/^# Container Check$/,/^## VM ##$/p' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/single.sh"

PATH="$WORK_DIR:$PATH" bash -c '
  set -euo pipefail
  LOCAL_FILES="$1/local"; mkdir -p "$LOCAL_FILES/temp"
  PCT_STATE="$1/pct-state"; PCT_CALLS="$1/pct-calls"; export PCT_STATE PCT_CALLS
  RECORDS="$1/records"; export RECORDS
  printf "status: stopped\n" > "$PCT_STATE"
  STOPPED=true; RUNNING=true; RDU=false; CHECK_FAILURE=0; STATUS_MODEL_NODE=node2
  YL="" CL="" RD="" GN="" BL="" OS=debian
  RUN_PROXMOX_COMMAND() { "$@"; }
  RUN_PROXMOX_CAPTURE() { "$@"; }
  cluster_target_guest_name() { printf "fixture\n"; }
  WAIT_FOR_BOOTUP_LXC() { return 0; }
  source "$1/single.sh"
  STATUS_MODEL_RECORD() { printf "%s\n" "$*" >> "$RECORDS"; }
  # The extracted check function is exercised only for lifecycle decisions.
  CHECK_CONTAINER() { printf "checked\n" >> "$PCT_CALLS"; return 0; }
  CHECK_SINGLE_CONTAINER 930
  grep -Fxq start "$PCT_CALLS"
  grep -Fxq shutdown "$PCT_CALLS"
  [[ "$(cat "$PCT_STATE")" == "status: stopped" ]]

  : > "$PCT_CALLS"; printf "status: stopped\n" > "$PCT_STATE"; STOPPED=false
  CHECK_SINGLE_CONTAINER 930
  ! grep -Eq "^(start|shutdown|checked)$" "$PCT_CALLS"
' _ "$WORK_DIR"

echo 'single LXC lifecycle semantics: PASS'
