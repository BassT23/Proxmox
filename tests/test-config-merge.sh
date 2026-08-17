#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/config-merge.sh"

cat > "$WORK_DIR/default.conf" <<'EOF'
# General
VERSION="2.1"
KEEP_ME="new-default"

# Proxmox storage ID used for backups.
BACKUP_STORAGE=""

# Newly introduced boolean.
NEW_OPTION=true
EOF

cat > "$WORK_DIR/user.conf" <<'EOF'
# my local note
VERSION="2.0"
KEEP_ME="user value with spaces"
CUSTOM_FOO="bar"
EMPTY=""
SINGLE='quoted value'
EOF

MERGE_UPDATE_CONFIG "$WORK_DIR/user.conf" "$WORK_DIR/default.conf"
grep -Fqx 'VERSION="2.1"' "$WORK_DIR/user.conf"
grep -Fqx 'KEEP_ME="user value with spaces"' "$WORK_DIR/user.conf"
grep -Fqx 'CUSTOM_FOO="bar"' "$WORK_DIR/user.conf"
grep -Fqx 'BACKUP_STORAGE=""' "$WORK_DIR/user.conf"
grep -Fqx 'NEW_OPTION=true' "$WORK_DIR/user.conf"
grep -Fqx '# Proxmox storage ID used for backups.' "$WORK_DIR/user.conf"
[[ $(grep -c '^BACKUP_STORAGE=' "$WORK_DIR/user.conf") -eq 1 ]]

first_hash=$(sha256sum "$WORK_DIR/user.conf" | awk '{print $1}')
MERGE_UPDATE_CONFIG "$WORK_DIR/user.conf" "$WORK_DIR/default.conf"
second_hash=$(sha256sum "$WORK_DIR/user.conf" | awk '{print $1}')
[[ "$first_hash" == "$second_hash" ]]

printf 'BROKEN="unterminated\n' >> "$WORK_DIR/user.conf"
cp "$WORK_DIR/user.conf" "$WORK_DIR/invalid-before.conf"
if MERGE_UPDATE_CONFIG "$WORK_DIR/user.conf" "$WORK_DIR/default.conf"; then
  echo 'invalid source unexpectedly accepted' >&2
  exit 1
fi
if ! cmp -s "$WORK_DIR/user.conf" "$WORK_DIR/invalid-before.conf"; then
  echo 'invalid fixture did not remain unchanged' >&2
  exit 1
fi

mkdir "$WORK_DIR/not-a-file"
if MERGE_UPDATE_CONFIG "$WORK_DIR/not-a-file" "$WORK_DIR/default.conf"; then
  echo 'directory target unexpectedly accepted' >&2
  exit 1
fi

echo 'config merge tests: PASS'
