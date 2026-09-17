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
  snapshot) printf '%s\n' "${SNAPSHOT_MESSAGE:-snapshot feature is not available}" >&2; exit "${SNAPSHOT_RC:-255}" ;;
  config) [[ "${MP_LINES:-}" == true ]] && printf 'mp0: /data\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK_DIR/vzdump" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected backup\n' >> "$BACKUP_CALLS"
exit 0
EOF
chmod 750 "$WORK_DIR/pct" "$WORK_DIR/vzdump"

PATH="$WORK_DIR:$PATH" BACKUP_CALLS="$WORK_DIR/backups" SNAPSHOT_RC=0 MP_LINES=true bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=false BACKUP_LXC_MP=true CONTAINER=230 KEEP_SNAPSHOT=3
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  CONTAINER_BACKUP
  [[ ! -e "$2" ]]
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"

# An unsupported snapshot must select the explicit mount-point fallback.
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
PATH="$WORK_DIR:$PATH" BACKUP_CALLS="$WORK_DIR/backups" SNAPSHOT_RC=255 MP_LINES=true bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=true BACKUP_LXC_MP=false CONTAINER=230 KEEP_SNAPSHOT=3 BACKUP_STORAGE=pbs BACKUP_MODE=stop
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  GET_BACKUP_STORAGE() { printf "pbs\n"; }
  CONTAINER_BACKUP
  [[ "$(wc -l < "$2")" == 1 ]]
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"

# A failed fallback must block the simulated guest update.
cat > "$WORK_DIR/vzdump" <<'EOF'
#!/usr/bin/env bash
printf 'backup-failed\n' >> "$BACKUP_CALLS"
exit 7
EOF
chmod 750 "$WORK_DIR/vzdump"
if PATH="$WORK_DIR:$PATH" BACKUP_CALLS="$WORK_DIR/backups" SNAPSHOT_RC=255 MP_LINES=true bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=false BACKUP_LXC_MP=true CONTAINER=230 KEEP_SNAPSHOT=3
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  GET_BACKUP_STORAGE() { printf "pbs\n"; }
  CONTAINER_BACKUP
  : > "$2/package-update-executed"
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"; then
  echo 'failed mount-point backup allowed guest update' >&2
  exit 1
fi
[[ ! -e "$WORK_DIR/backups/package-update-executed" ]]

# Without an explicit fallback, an unsupported configured snapshot is a safety
# failure rather than permission to continue unprotected.
if PATH="$WORK_DIR:$PATH" SNAPSHOT_RC=255 MP_LINES=true bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=false BACKUP_LXC_MP=false CONTAINER=230 KEEP_SNAPSHOT=3
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  CONTAINER_BACKUP
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"; then
  echo 'unsupported snapshot without fallback did not fail safely' >&2
  exit 1
fi

# No mount point means BACKUP_LXC_MP must not activate the fallback.
if PATH="$WORK_DIR:$PATH" SNAPSHOT_RC=255 MP_LINES=false bash -c '
  set -euo pipefail
  source "$3"
  source "$1"
  SNAPSHOT=true BACKUP=false BACKUP_LXC_MP=true CONTAINER=230 KEEP_SNAPSHOT=3
  RD= OR= GN= CL= BACKUP_CALLS="$2"
  CONTAINER_BACKUP
' _ "$WORK_DIR/container-backup.sh" "$WORK_DIR/backups" "$ROOT_DIR/target-runtime.sh"; then
  echo 'mount-point fallback activated without a mount point' >&2
  exit 1
fi

grep -Fq 'TEMP_STATE_DIR="${UU_TEMP_STATE_DIR:-$LOCAL_FILES/temp}"' "$ROOT_DIR/update.sh"
grep -Fq '"$TEMP_STATE_DIR/var"' "$ROOT_DIR/update.sh"
grep -Fq '"$LOCAL_FILES/exit/error.sh"' "$ROOT_DIR/ultimate-updater"
grep -Fq '$remote_update_dir/exit/$(basename -- "$source")' "$ROOT_DIR/ultimate-updater"

printf 'snapshot/backup semantics tests: PASS\n'
