#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cp "$ROOT_DIR/target-inventory.sh" "$WORK_DIR/target-inventory.sh"
chmod 750 "$WORK_DIR/target-inventory.sh"
mkdir -p "$WORK_DIR/VMs"

cat > "$WORK_DIR/VMs/155" <<'EOF'
IP="10.0.0.155"
USER="admin"
SSH_VM_PORT="2222"
SSH_START_DELAY_TIME="15"
EOF
cat > "$WORK_DIR/VMs/156" <<'EOF'
IP="10.0.0.156"
USER="root"
SSH_VM_PORT="22"
EOF

cat > "$WORK_DIR/targets.conf" <<'EOF'
[raspi]
host=10.0.0.50
transport=ssh
user=uu-ext
port=22

[legacy-155]
host=10.0.0.155
transport=ssh
user=admin
port=2222

[legacy-156]
host=10.0.0.156
transport=ssh
user=root
port=22
EOF
printf 'fingerprint=old\nmanual_review=0\n' > "$WORK_DIR/legacy-migration.state"

UU_LOCAL_FILES="$WORK_DIR" UU_LEGACY_MIGRATION_LOG="$WORK_DIR/migration.log" \
  "$ROOT_DIR/legacy-migrate.sh" > "$WORK_DIR/output"

if grep -Eq '^\[legacy-(155|156)\]$' "$WORK_DIR/targets.conf"; then
  echo 'internal VM SSH profiles were left as external targets' >&2
  exit 1
fi
grep -Fqx '[raspi]' "$WORK_DIR/targets.conf"
grep -Fq 'Removed 2 obsolete internal VM SSH entries' "$WORK_DIR/output"
grep -Fq 'REMOVED_BUG_GENERATED [legacy-155]' "$WORK_DIR/migration.log"
grep -Fq 'REMOVED_BUG_GENERATED [legacy-156]' "$WORK_DIR/migration.log"
compgen -G "$WORK_DIR/targets.conf.bak*" >/dev/null

# Cleanup is idempotent and does not touch real external targets.
before=$(sha256sum "$WORK_DIR/targets.conf" | awk '{print $1}')
UU_LOCAL_FILES="$WORK_DIR" UU_LEGACY_MIGRATION_LOG="$WORK_DIR/migration.log" \
  "$ROOT_DIR/legacy-migrate.sh" > "$WORK_DIR/second.out"
after=$(sha256sum "$WORK_DIR/targets.conf" | awk '{print $1}')
[[ "$before" == "$after" ]]
[[ ! -s "$WORK_DIR/second.out" ]]

# Without migration evidence, an ambiguous legacy-named external is preserved.
mkdir -p "$WORK_DIR/no-evidence/VMs"
cp "$WORK_DIR/VMs/155" "$WORK_DIR/no-evidence/VMs/155"
cp "$WORK_DIR/target-inventory.sh" "$WORK_DIR/no-evidence/target-inventory.sh"
chmod 750 "$WORK_DIR/no-evidence/target-inventory.sh"
cat > "$WORK_DIR/no-evidence/targets.conf" <<'EOF'
[legacy-155]
host=10.0.0.155
transport=ssh
user=admin
port=2222
EOF
UU_LOCAL_FILES="$WORK_DIR/no-evidence" "$ROOT_DIR/legacy-migrate.sh" >/dev/null
grep -Fqx '[legacy-155]' "$WORK_DIR/no-evidence/targets.conf"

# The production VM path still reads VMs/<VMID>; no external migration call is
# needed for internal VM SSH fallback.
grep -Fq 'LOCAL_FILES/VMs/$VM' "$ROOT_DIR/update.sh"
grep -Fq 'LOCAL_FILES/VMs/"$VM"' "$ROOT_DIR/check-updates.sh"

echo 'legacy internal VM SSH migration tests: PASS'
