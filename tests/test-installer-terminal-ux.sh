#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin"
INSTALLER="$WORK_DIR/install.sh"
cp "$ROOT_DIR/install.sh" "$INSTALLER"
sed -i '0,/^  CHECK_ROOT$/s//  :/' "$INSTALLER"
cat > "$WORK_DIR/bin/clear" <<'EOF'
#!/bin/sh
printf '__UU_CLEAR__'
EOF
chmod 755 "$WORK_DIR/bin/clear"

run_tty() {
  local output=$1 command=$2
  script -qefc "env PATH=$WORK_DIR/bin:\$PATH TERM=xterm $command" "$output" >/dev/null 2>&1 || true
}

assert_clear_before_header() {
  local output=$1
  grep -Fq '__UU_CLEAR__' "$output"
  grep -Fq 'https://github.com/BassT23/Proxmox' "$output"
  [[ "$(grep -abo '__UU_CLEAR__' "$output" | head -n1 | cut -d: -f1)" -lt \
     "$(grep -abo 'https://github.com/BassT23/Proxmox' "$output" | head -n1 | cut -d: -f1)" ]]
}

output="$WORK_DIR/direct.typescript"
run_tty "$output" "bash $INSTALLER -h"
assert_clear_before_header "$output"

# The real self-update keeps stdin attached to the controlling terminal while
# update.sh has already sent stdout through tee. /dev/tty must still receive
# the clear sequence in this stdout-pipe case.
output="$WORK_DIR/self-update.typescript"
run_tty "$output" "UU_NONINTERACTIVE=true UU_INTERACTIVE_INSTALLER=true bash $INSTALLER -h | cat"
assert_clear_before_header "$output"

output="$WORK_DIR/headless.typescript"
run_tty "$output" "UU_NONINTERACTIVE=true bash $INSTALLER -h"
! grep -Fq '__UU_CLEAR__' "$output"

output="$WORK_DIR/scheduler.typescript"
run_tty "$output" "UU_JOB_SOURCE=scheduler bash $INSTALLER -h"
! grep -Fq '__UU_CLEAR__' "$output"

output="$WORK_DIR/managed.typescript"
run_tty "$output" "UU_MANAGED_OUTPUT=true bash $INSTALLER -h"
! grep -Fq '__UU_CLEAR__' "$output"

output="$WORK_DIR/dumb.typescript"
run_tty "$output" "TERM=dumb bash $INSTALLER -h"
! grep -Fq '__UU_CLEAR__' "$output"

output="$WORK_DIR/non-tty"
env PATH="$WORK_DIR/bin:$PATH" TERM=xterm bash "$INSTALLER" -h >"$output" 2>&1
! grep -Fq '__UU_CLEAR__' "$output"

# Exercise update.sh's own header decision without running the full updater.
awk '/^SHOULD_CLEAR_UPDATE_HEADER\(\)/{capture=1} capture {if (/^# Version Check/) exit; print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/update-header.sh"
output="$WORK_DIR/update-header.typescript"
run_tty "$output" "bash -c 'source $WORK_DIR/update-header.sh; INFO=false; HEADER_INFO'"
assert_clear_before_header "$output"

output="$WORK_DIR/update-managed.typescript"
run_tty "$output" "UU_NONINTERACTIVE=true bash -c 'source $WORK_DIR/update-header.sh; INFO=false; HEADER_INFO'"
! grep -Fq '__UU_CLEAR__' "$output"

if grep -Fq 'Installing:' "$ROOT_DIR/install.sh"; then
  echo 'redundant installer progress line remains' >&2
  exit 1
fi
grep -Fq 'Installed: $(FORMAT_ARCHIVE_IDENTITY)' "$ROOT_DIR/install.sh"
grep -Fq 'UU_INTERACTIVE_INSTALLER=true' "$ROOT_DIR/update.sh"
! grep -Fq 'clear >/dev/null' "$ROOT_DIR/install.sh" "$ROOT_DIR/update.sh"

echo 'installer terminal UX tests: PASS'
