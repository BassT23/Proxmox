#!/bin/bash
set -euo pipefail

ROOT_DIR=$(dirname -- "${BASH_SOURCE[0]}")/..
ROOT_DIR=$(cd -- "$ROOT_DIR" && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/config-merge.sh"

assert_clean_command () {
  local stderr_file rc
  stderr_file=$(mktemp)
  set +e
  "$@" 2>"$stderr_file"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    cat "$stderr_file" >&2
    echo "command unexpectedly failed: $*" >&2
    exit 1
  fi
  if [[ -s "$stderr_file" ]]; then
    cat "$stderr_file" >&2
    echo "command wrote unexpected stderr: $*" >&2
    exit 1
  fi
  rm -f "$stderr_file"
}

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
ESCAPED="hello \"world\""
TRAILING_COMMENT="value" # comment
EOF

assert_clean_command MERGE_UPDATE_CONFIG "$WORK_DIR/user.conf" "$WORK_DIR/default.conf"
grep -Fqx 'VERSION="2.1"' "$WORK_DIR/user.conf"
grep -Fqx 'KEEP_ME="user value with spaces"' "$WORK_DIR/user.conf"
grep -Fqx 'CUSTOM_FOO="bar"' "$WORK_DIR/user.conf"
grep -Fqx 'BACKUP_STORAGE=""' "$WORK_DIR/user.conf"
grep -Fqx 'NEW_OPTION=true' "$WORK_DIR/user.conf"
grep -Fqx '# Proxmox storage ID used for backups.' "$WORK_DIR/user.conf"
[[ $(grep -c '^BACKUP_STORAGE=' "$WORK_DIR/user.conf") -eq 1 ]]

first_hash=$(sha256sum "$WORK_DIR/user.conf" | awk '{print $1}')
assert_clean_command MERGE_UPDATE_CONFIG "$WORK_DIR/user.conf" "$WORK_DIR/default.conf"
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

cat > "$WORK_DIR/valid-values.conf" <<'EOF'
DOUBLE="hello world"
ESCAPED="hello \"world\""
SINGLE='hello world'
BARE=true
NUMBER=123
COMMENT="value" # comment
EOF
assert_clean_command CONFIG_MERGE_VALIDATE "$WORK_DIR/valid-values.conf"

cat > "$WORK_DIR/invalid-values.conf" <<'EOF'
OPEN="broken
WHITESPACE=hello world
EOF
if CONFIG_MERGE_VALIDATE "$WORK_DIR/invalid-values.conf" >/dev/null 2>"$WORK_DIR/invalid-values.stderr"; then
  echo 'invalid values unexpectedly accepted' >&2
  exit 1
fi

# The first functional reboot implementation must neutralize the historical
# inactive true default exactly once, while preserving unrelated settings.
cat > "$WORK_DIR/legacy-reboot.conf" <<'EOF'
KEEP_ME="preserved"
REBOOT_IF_NEEDED="true"
BACKUP="false"
EOF
assert_clean_command MIGRATE_REBOOT_IF_NEEDED "$WORK_DIR/legacy-reboot.conf"
grep -Fqx 'REBOOT_IF_NEEDED="false"    # migrated from the legacy inactive default' "$WORK_DIR/legacy-reboot.conf"
grep -Fqx 'KEEP_ME="preserved"' "$WORK_DIR/legacy-reboot.conf"
grep -Fqx 'previous_value=true' "$WORK_DIR/legacy-reboot.conf.reboot-if-needed-migrated-v1"
grep -Fqx 'new_value=false' "$WORK_DIR/legacy-reboot.conf.reboot-if-needed-migrated-v1"
grep -Fqx 'REBOOT_IF_NEEDED="true"' "$WORK_DIR/legacy-reboot.conf.reboot-if-needed.pre-v1"
legacy_hash=$(sha256sum "$WORK_DIR/legacy-reboot.conf" | awk '{print $1}')
assert_clean_command MIGRATE_REBOOT_IF_NEEDED "$WORK_DIR/legacy-reboot.conf"
[[ "$legacy_hash" == "$(sha256sum "$WORK_DIR/legacy-reboot.conf" | awk '{print $1}')" ]]

# A later administrator choice is not reverted on subsequent migrations.
sed -i 's/REBOOT_IF_NEEDED="false".*/REBOOT_IF_NEEDED="true"/' "$WORK_DIR/legacy-reboot.conf"
assert_clean_command MIGRATE_REBOOT_IF_NEEDED "$WORK_DIR/legacy-reboot.conf"
grep -Fqx 'REBOOT_IF_NEEDED="true"' "$WORK_DIR/legacy-reboot.conf"

# A symlink must fail closed rather than allowing the migration to follow it.
ln -s "$WORK_DIR/legacy-reboot.conf" "$WORK_DIR/reboot-symlink.conf"
if MIGRATE_REBOOT_IF_NEEDED "$WORK_DIR/reboot-symlink.conf" >/dev/null 2>"$WORK_DIR/reboot-symlink.stderr"; then
  echo 'reboot migration unexpectedly followed a symlink' >&2
  exit 1
fi

echo 'config merge tests: PASS'
