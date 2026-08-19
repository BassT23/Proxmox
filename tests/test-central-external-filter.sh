#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/update.conf" <<'CONFIG'
ONLY_UPDATE_CHECK="check-only"
EXCLUDE_UPDATE_CHECK=""
CONFIG
cat > "$WORK_DIR/targets.conf" <<'CONFIG'
[mediacenter]
host=192.0.2.10
transport=ssh
user=root
[legacy-978]
host=192.0.2.11
transport=ssh
user=root
[legacy-971]
host=192.0.2.12
transport=ssh
user=root
CONFIG
cat > "$WORK_DIR/check-updates.sh" <<'CHECK'
#!/usr/bin/env bash
exit 0
CHECK
cat > "$WORK_DIR/external-apt.sh" <<'EXTERNAL'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$UU_EXTERNAL_CALLS"
exit 0
EXTERNAL
chmod +x "$WORK_DIR/check-updates.sh" "$WORK_DIR/external-apt.sh"

UU_LOCAL_FILES="$WORK_DIR" UU_EXTERNAL_CALLS="$WORK_DIR/calls" \
  "$ROOT_DIR/ultimate-updater" check >/dev/null
grep -Fxq 'mediacenter' "$WORK_DIR/calls"
grep -Fxq 'legacy-978' "$WORK_DIR/calls"
grep -Fxq 'legacy-971' "$WORK_DIR/calls"

sed -i 's/ONLY_UPDATE_CHECK="check-only"/ONLY_UPDATE_CHECK=""/; s/EXCLUDE_UPDATE_CHECK=""/EXCLUDE_UPDATE_CHECK="legacy-971"/' "$WORK_DIR/update.conf"
: > "$WORK_DIR/calls"
UU_LOCAL_FILES="$WORK_DIR" UU_EXTERNAL_CALLS="$WORK_DIR/calls" \
  "$ROOT_DIR/ultimate-updater" check >/dev/null
grep -Fxq 'mediacenter' "$WORK_DIR/calls"
grep -Fxq 'legacy-978' "$WORK_DIR/calls"
if grep -Fxq 'legacy-971' "$WORK_DIR/calls"; then
  exit 1
fi

echo 'central external filter dispatch: PASS'
