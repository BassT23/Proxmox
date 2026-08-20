#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs"

cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK_DIR/bin/systemd-run"

cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$WORK_DIR/bin/systemctl"

printf '#!/usr/bin/env bash\nsleep 1\n' > "$WORK_DIR/update.sh"
chmod +x "$WORK_DIR/update.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_DIR/check.sh"
chmod +x "$WORK_DIR/check.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo 'job concurrency and stale safety: PASS (runtime fixture skipped: root required)'
  exit 0
fi

runner=(env UU_JOB_STATE_DIR="$WORK_DIR/jobs" PATH="$WORK_DIR/bin:$PATH" "$ROOT_DIR/job-runner.sh")

first=$("${runner[@]}" start "$WORK_DIR/update.sh" 191)
grep -Fq 'Update job started' <<< "$first"
first_unit=$(awk '/^Job:/{print $2}' <<< "$first")

if second=$("${runner[@]}" start "$WORK_DIR/update.sh" 191 2>&1); then
  echo 'duplicate update was accepted' >&2
  exit 1
fi
grep -Fq 'A job is already running for target 191' <<< "$second"
grep -Fq "^state=running$" "$WORK_DIR/jobs/$first_unit.state"

if check_conflict=$("${runner[@]}" start-check 191 "$WORK_DIR/check.sh" target 2>&1); then
  echo 'check/update conflict was accepted' >&2
  exit 1
fi
grep -Fq 'A job is already running for target 191' <<< "$check_conflict"
grep -Fq "^state=running$" "$WORK_DIR/jobs/$first_unit.state"

other=$("${runner[@]}" start-check 230 "$WORK_DIR/check.sh" target)
grep -Fq 'Check job started' <<< "$other"
other_unit=$(awk '/^Job:/{print $2}' <<< "$other")
grep -Fq "^state=running$" "$WORK_DIR/jobs/$other_unit.state"

if global_conflict=$("${runner[@]}" start-global "$WORK_DIR/update.sh" 2>&1); then
  echo 'global update conflict was accepted' >&2
  exit 1
fi
grep -Fq 'A job is already running; the full update was not started' <<< "$global_conflict"
grep -Fq "^state=running$" "$WORK_DIR/jobs/$first_unit.state"

# An unavailable systemd query must not convert an active state file to
# interrupted merely because stale detection cannot prove the unit is gone.
list_output=$("${runner[@]}" list)
grep -Fq "$first_unit" <<< "$list_output"
grep -Fq "$other_unit" <<< "$list_output"
grep -Fq $'\trunning\t' <<< "$list_output"

echo 'job concurrency and stale safety: PASS'
