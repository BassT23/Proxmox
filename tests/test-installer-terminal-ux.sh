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
printf 'x' >> "$UU_CLEAR_MARKER"
EOF
chmod 755 "$WORK_DIR/bin/clear"

run_tty() {
  local marker="$1"; shift
  : > "$marker"
  script -qefc "env PATH=$WORK_DIR/bin:\$PATH UU_CLEAR_MARKER=$marker $*" /dev/null >/dev/null 2>&1
}

marker="$WORK_DIR/interactive"
run_tty "$marker" "bash $INSTALLER -h"
[[ "$(cat "$marker")" == x ]]

marker="$WORK_DIR/self-update"
run_tty "$marker" "UU_NONINTERACTIVE=true UU_INTERACTIVE_INSTALLER=true bash $INSTALLER -h"
[[ "$(cat "$marker")" == x ]]

marker="$WORK_DIR/headless"
run_tty "$marker" "UU_NONINTERACTIVE=true bash $INSTALLER -h"
[[ ! -s "$marker" ]]

marker="$WORK_DIR/dumb"
run_tty "$marker" "TERM=dumb bash $INSTALLER -h"
[[ ! -s "$marker" ]]

marker="$WORK_DIR/non-tty"
: > "$marker"
env PATH="$WORK_DIR/bin:$PATH" UU_CLEAR_MARKER="$marker" TERM=xterm bash "$INSTALLER" -h >/dev/null 2>&1
[[ ! -s "$marker" ]]

if grep -Fq 'Installing:' "$ROOT_DIR/install.sh"; then
  echo 'redundant installer progress line remains' >&2
  exit 1
fi
grep -Fq 'Installed: $(FORMAT_ARCHIVE_IDENTITY)' "$ROOT_DIR/install.sh"
grep -Fq 'UU_INTERACTIVE_INSTALLER=true' "$ROOT_DIR/update.sh"

echo 'installer terminal UX tests: PASS'
