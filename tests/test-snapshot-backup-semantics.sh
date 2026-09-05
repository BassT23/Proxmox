#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^CONTAINER_BACKUP \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/container-backup.sh"

cat > "$WORK_DIR/pct" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  snapshot) printf 'snapshot feature is not available\n' >&2; exit 255 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK_DIR/vzdump" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected backup\n' >> "$BACKUP_CALLS"
exit 0
EOF
chmod 750 "$WORK_DIR/pct" "$WORK_DIR/vzdump"

PATH="$WORK_DIR:$PATH" BACKUP_CALLS="$WORK_DIR/backups" bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=false BACKUP_LXC_MP=true CONTAINER=230 KEEP_SNAPSHOT=3
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  CONTAINER_BACKUP
  [[ ! -e "$2" ]]
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"

# An unsupported snapshot must not prevent an explicitly enabled backup.
cat > "$WORK_DIR/pvesm" <<'EOF'
#!/usr/bin/env bash
printf 'pbs dir active\n'
EOF
cat > "$WORK_DIR/vzdump" <<'EOF'
#!/usr/bin/env bash
printf 'backup\n' >> "$BACKUP_CALLS"
exit 0
EOF
chmod 750 "$WORK_DIR/pvesm" "$WORK_DIR/vzdump"
PATH="$WORK_DIR:$PATH" BACKUP_CALLS="$WORK_DIR/backups" bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=true BACKUP_LXC_MP=false CONTAINER=230 KEEP_SNAPSHOT=3 BACKUP_STORAGE=pbs BACKUP_MODE=stop
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  GET_BACKUP_STORAGE() { printf "pbs\n"; }
  CONTAINER_BACKUP
  grep -Fq backup "$2"
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"

grep -Fq 'TEMP_STATE_DIR="${UU_TEMP_STATE_DIR:-$LOCAL_FILES/temp}"' "$ROOT_DIR/update.sh"
grep -Fq '"$TEMP_STATE_DIR/var"' "$ROOT_DIR/update.sh"
grep -Fq '"$LOCAL_FILES/exit/error.sh"' "$ROOT_DIR/ultimate-updater"
grep -Fq '$remote_update_dir/exit/$(basename -- "$source")' "$ROOT_DIR/ultimate-updater"

printf 'snapshot/backup semantics tests: PASS\n'
