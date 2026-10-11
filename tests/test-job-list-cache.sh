#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"

# A cached list must not invoke SSH. If it does, this deliberately slow fake
# makes the regression visible without contacting a real host.
cat > "$WORK_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
sleep 10
exit 1
EOF
chmod 755 "$WORK_DIR/bin/ssh"
export PATH="$WORK_DIR/bin:$PATH"

for index in $(seq -w 1 50); do
  unit="ultimate-updater-check-test-${index}"
  cat > "$WORK_DIR/jobs/${unit}.state" <<EOF
schema_version=1
unit=${unit}
target=986
state=completed
started_at=2026-10-11T10:00:00Z
finished_at=2026-10-11T10:01:00Z
exit_code=0
type=check
source=
interactive=false
EOF
done

for index in $(seq -w 1 10); do
  unit="ultimate-updater-update-986-cache-${index}"
  cat > "$WORK_DIR/jobs/remote/${unit}.ref" <<EOF
schema_version=1
unit=${unit}
target=986
owner_node=test-node1
owner_host=127.0.0.1
port=22
registered_at=2026-10-11T10:00:00Z
status_refresh=pending
workspace=
EOF
done

START=$(date +%s)
UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" \
  timeout 3 "$ROOT_DIR/job-runner.sh" list --cached > "$WORK_DIR/list"
ELAPSED=$(( $(date +%s) - START ))

test "$ELAPSED" -lt 3
test "$(wc -l < "$WORK_DIR/list")" -eq 60
grep -Fq $'ultimate-updater-check-test-01\t986\tcompleted' "$WORK_DIR/list"
grep -Fq $'ultimate-updater-update-986-cache-01\t986\tremote_unavailable' "$WORK_DIR/list"

echo 'cached job list tests: PASS'
