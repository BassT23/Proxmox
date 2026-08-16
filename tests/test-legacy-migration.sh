#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$ROOT_DIR/target-inventory.sh" "$WORK_DIR/target-inventory.sh"
chmod 750 "$WORK_DIR/target-inventory.sh"
mkdir -p "$WORK_DIR/VMs"

cat > "$WORK_DIR/targets.conf" <<'EOF'
# Existing user-managed inventory must remain unchanged.
[existing]
host=10.0.0.10
transport=ssh
user=admin
port=22
identity_file=/root/.ssh/legacy-key

[plain-existing]
host=10.0.0.11
transport=ssh
user=root
port=22
EOF

cat > "$WORK_DIR/VMs/927" <<'EOF'
# Historical SSH definition.
IP="10.0.0.27" # inline comments are supported
USER="uu-ext"
SSH_VM_PORT="2222"
SSH_START_DELAY_TIME="45"
CUSTOM_NOTE="preserve as report only"
EOF

cat > "$WORK_DIR/VMs/928" <<'EOF'
IP="10.0.0.10"
USER="admin"
SSH_VM_PORT="22"
EOF

cat > "$WORK_DIR/VMs/929" <<'EOF'
IP="$(touch /tmp/legacy-migration-must-not-run)"
USER="root"
SSH_VM_PORT="22"
EOF

cat > "$WORK_DIR/VMs/930" <<'EOF'
IP="10.0.0.30"
USER="root"
SSH_VM_PORT="22"
EOF

cat > "$WORK_DIR/VMs/931" <<'EOF'
IP="10.0.0.11"
USER="root"
SSH_VM_PORT="22"
EOF

cat >> "$WORK_DIR/targets.conf" <<'EOF'

[legacy-930]
host=10.0.0.31
transport=ssh
user=root
port=22
identity_file=/root/.ssh/other-key
EOF

UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/legacy-migrate.sh" > "$WORK_DIR/first.out"

grep -Fq 'Migrated: 1' "$WORK_DIR/first.out"
grep -Fq 'SKIPPED_DUPLICATE' "$WORK_DIR/first.out"
grep -Fq 'SKIPPED_INVALID' "$WORK_DIR/first.out"
grep -Fq 'MANUAL_REVIEW_REQUIRED' "$WORK_DIR/first.out"
grep -Fqx 'host=10.0.0.27' <(sed -n '/\[legacy-927\]/,/^$/p' "$WORK_DIR/targets.conf")
grep -Fqx 'user=uu-ext' <(sed -n '/\[legacy-927\]/,/^$/p' "$WORK_DIR/targets.conf")
grep -Fqx 'port=2222' <(sed -n '/\[legacy-927\]/,/^$/p' "$WORK_DIR/targets.conf")
grep -Fq 'identity_file=/root/.ssh/legacy-key' "$WORK_DIR/targets.conf"
[[ ! -e /tmp/legacy-migration-must-not-run ]]
[[ -f "$WORK_DIR/VMs/927" && -f "$WORK_DIR/VMs/928" ]]

first_hash=$(sha256sum "$WORK_DIR/targets.conf" | awk '{print $1}')
UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/legacy-migrate.sh" > "$WORK_DIR/second.out"
second_hash=$(sha256sum "$WORK_DIR/targets.conf" | awk '{print $1}')
[[ "$first_hash" == "$second_hash" ]]
[[ $(grep -c '^\[legacy-927\]$' "$WORK_DIR/targets.conf") -eq 1 ]]

printf '[broken]\nnot-valid\n' > "$WORK_DIR/targets.conf"
cp "$WORK_DIR/targets.conf" "$WORK_DIR/before-invalid.conf"
if UU_LOCAL_FILES="$WORK_DIR" "$ROOT_DIR/legacy-migrate.sh" > "$WORK_DIR/invalid.out"; then
  echo 'invalid inventory unexpectedly migrated' >&2
  exit 1
fi
cmp -s "$WORK_DIR/targets.conf" "$WORK_DIR/before-invalid.conf"

echo 'legacy migration tests: PASS'

