#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

helper=$(sed -n '/^ensure_scheduled_check_cron() {/,/^OLD_FILESYSTEM_CHECK () {/p' "$ROOT_DIR/install.sh" | sed '$d')
eval "$helper"

fresh="$WORK_DIR/fresh.cron"
: > "$fresh"
ensure_scheduled_check_cron "$fresh"
grep -Fq '00 06   * * *   root RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/update -check >/dev/null 2>&1' "$fresh"

legacy="$WORK_DIR/legacy.cron"
cat > "$legacy" <<'EOF'
# unrelated entry
00 06 * * * root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1
EOF
ensure_scheduled_check_cron "$legacy"
grep -Fq '00 06 * * * root RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/update -check >/dev/null 2>&1' "$legacy"
grep -Fq '# unrelated entry' "$legacy"

known_legacy="$WORK_DIR/known-legacy.cron"
printf '00 06 * * * root RUN_FROM_CRON=true /etc/ultimate-updater/check-updates.sh >/dev/null 2>&1\n' > "$known_legacy"
ensure_scheduled_check_cron "$known_legacy"
grep -Fq 'RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /etc/ultimate-updater/check-updates.sh' "$known_legacy"

custom="$WORK_DIR/custom.cron"
printf '30 04 * * * root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1\n' > "$custom"
ensure_scheduled_check_cron "$custom"
grep -Fq '30 04 * * *' "$custom"
grep -Fq 'RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler' "$custom"

before=$(sha256sum "$custom")
ensure_scheduled_check_cron "$custom"
after=$(sha256sum "$custom")
[[ "$before" == "$after" ]]
[[ $(grep -Fc 'update -check' "$custom") -eq 1 ]]
[[ $(grep -Fc 'UU_JOB_SOURCE=scheduler' "$custom") -eq 1 ]]

unrelated="$WORK_DIR/unrelated.cron"
cat > "$unrelated" <<'EOF'
15 02 * * * root /usr/local/sbin/backup
12 03 * * * root /opt/vendor/check-updates.sh
13 04 * * * root /home/test/check-updates.sh --foo
EOF
before=$(sha256sum "$unrelated")
ensure_scheduled_check_cron "$unrelated" false
after=$(sha256sum "$unrelated")
[[ "$before" == "$after" ]]
grep -Fq '/usr/local/sbin/backup' "$unrelated"

backup_source="$WORK_DIR/backup-source.cron"
backup_dir="$WORK_DIR/backups"
printf '30 04 * * * root RUN_FROM_CRON=true /usr/local/sbin/update -check >/dev/null 2>&1\n' > "$backup_source"
before_content=$(cat "$backup_source")
UU_CRON_BACKUP_DIR="$backup_dir" ensure_scheduled_check_cron "$backup_source"
backup=$(find "$backup_dir" -type f -name 'backup-source.cron.bak.*' -print -quit)
[[ -n "$backup" ]]
[[ "$(cat "$backup")" == "$before_content" ]]
[[ $(find "$backup_dir" -type f -name 'backup-source.cron.bak.*' | wc -l) -eq 1 ]]

noop="$WORK_DIR/noop.cron"
cp "$backup_source" "$noop"
before=$(sha256sum "$noop")
UU_CRON_BACKUP_DIR="$backup_dir" ensure_scheduled_check_cron "$noop"
after=$(sha256sum "$noop")
[[ "$before" == "$after" ]]
[[ $(find "$backup_dir" -type f -name 'noop.cron.bak.*' | wc -l) -eq 0 ]]

echo 'installer scheduled cron migration: PASS'
