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
30 04 * * * root /usr/local/sbin/other-job -check
EOF
ensure_scheduled_check_cron "$unrelated"
grep -Fq '/usr/local/sbin/backup' "$unrelated"
grep -Fq '/usr/local/sbin/other-job -check' "$unrelated"
grep -Fq 'RUN_FROM_CRON=true UU_JOB_SOURCE=scheduler /usr/local/sbin/update -check' "$unrelated"

echo 'installer scheduled cron migration: PASS'
