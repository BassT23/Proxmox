#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/update.conf" <<'CONFIG'
ONLY="rocky-984"
EXCLUDE="rocky-984"
EXIT_ON_ERROR="false"
CONFIG
cat > "$WORK_DIR/targets.conf" <<'CONFIG'
[rocky-984]
host=192.0.2.20
transport=ssh
user=root
[mediacenter]
host=192.0.2.21
transport=ssh
user=root
[legacy-971]
host=192.0.2.22
transport=ssh
user=root
CONFIG
cat > "$WORK_DIR/target-inventory.sh" <<'INVENTORY'
#!/usr/bin/env bash
declare -a TARGET_NAMES=()
declare -A TARGET_TRANSPORT=()
TARGET_INVENTORY_VALIDATE() {
  TARGET_NAMES=(rocky-984 mediacenter legacy-971)
  TARGET_TRANSPORT[rocky-984]=ssh
  TARGET_TRANSPORT[mediacenter]=ssh
  TARGET_TRANSPORT[legacy-971]=ssh
}
INVENTORY
cat > "$WORK_DIR/update.sh" <<'UPDATE'
#!/usr/bin/env bash
printf 'core update complete\n'
UPDATE
cat > "$WORK_DIR/external-apt.sh" <<'EXTERNAL'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$UU_EXTERNAL_CALLS"
printf 'mock external update success: %s\n' "$1"
if [[ "$1" == rocky-984 && "${UU_FAIL_EXTERNAL:-false}" == true ]]; then
  exit 42
fi
EXTERNAL
chmod +x "$WORK_DIR"/{target-inventory.sh,update.sh,external-apt.sh}

run_global() {
  UU_LOCAL_FILES="$WORK_DIR" UU_UPDATE_SCRIPT="$WORK_DIR/update.sh" \
    UU_INVENTORY_SCRIPT="$WORK_DIR/target-inventory.sh" \
    UU_EXTERNAL_SCRIPT="$WORK_DIR/external-apt.sh" UU_EXTERNAL_CALLS="$WORK_DIR/calls" \
    "$ROOT_DIR/global-update.sh"
}

output=$(run_global)
grep -Fq 'rocky-984 selected' <<<"$output"
grep -Fq 'mediacenter skipped by central update filter' <<<"$output"
grep -Fq 'legacy-971 skipped by central update filter' <<<"$output"
grep -Fxq rocky-984 "$WORK_DIR/calls"
if grep -Eq 'mediacenter|legacy-971' "$WORK_DIR/calls"; then
  echo 'filtered External target was contacted' >&2
  exit 1
fi

sed -i 's/ONLY="rocky-984"/ONLY=""/; s/EXCLUDE="rocky-984"/EXCLUDE="mediacenter"/' "$WORK_DIR/update.conf"
: > "$WORK_DIR/calls"
run_global >/dev/null
grep -Fxq rocky-984 "$WORK_DIR/calls"
grep -Fxq legacy-971 "$WORK_DIR/calls"
if grep -Fxq mediacenter "$WORK_DIR/calls"; then exit 1; fi

sed -i 's/EXCLUDE="mediacenter"/EXCLUDE=""/; s/EXIT_ON_ERROR="false"/EXIT_ON_ERROR="false"/' "$WORK_DIR/update.conf"
: > "$WORK_DIR/calls"
export UU_FAIL_EXTERNAL=true
if run_global >/dev/null 2>&1; then exit 1; fi
grep -Fxq rocky-984 "$WORK_DIR/calls"
grep -Fxq mediacenter "$WORK_DIR/calls"
grep -Fxq legacy-971 "$WORK_DIR/calls"

sed -i 's/EXIT_ON_ERROR="false"/EXIT_ON_ERROR="true"/' "$WORK_DIR/update.conf"
: > "$WORK_DIR/calls"
if run_global >/dev/null 2>&1; then exit 1; fi
grep -Fxq rocky-984 "$WORK_DIR/calls"
if [[ $(wc -l < "$WORK_DIR/calls") -ne 1 ]]; then exit 1; fi

echo 'global External update selection: PASS'
