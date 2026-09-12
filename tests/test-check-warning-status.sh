#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/jobs"

cat > "$WORK_DIR/warning-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'CHECK all systems completed with warnings'
exit 10
EOF
chmod +x "$WORK_DIR/warning-cli"

cat > "$WORK_DIR/hard-cli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'CHECK all systems failed' >&2
exit 1
EOF
chmod +x "$WORK_DIR/hard-cli"

write_running() {
  local unit="$1" target="$2"
  cat > "$WORK_DIR/jobs/$unit.state" <<EOF
schema_version=1
unit=$unit
target=$target
state=running
started_at=2026-08-23T00:00:00Z
finished_at=
exit_code=
type=check
message=
source=
EOF
}

warning_unit=ultimate-updater-check-all-systems-warning
write_running "$warning_unit" all-systems
UU_JOB_STATE_DIR="$WORK_DIR/jobs" bash "$ROOT_DIR/job-runner.sh" run-check \
  "$warning_unit" all-systems "$WORK_DIR/warning-cli" all
grep -Fxq 'state=completed_with_warnings' "$WORK_DIR/jobs/$warning_unit.state"
grep -Fxq 'exit_code=10' "$WORK_DIR/jobs/$warning_unit.state"

# The synchronous wrapper preserves the warning classification as a
# non-zero application result. Scheduler context must have the same contract.
cat > "$WORK_DIR/check-updates.sh" <<'EOF'
#!/usr/bin/env bash
cat > "$UU_LOCAL_FILES/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"fixture","check_status":"error","reachable":true,"error":{"code":"CHECK_FAILED"}}]}
JSON
printf '%s\n' 'CHECK all systems failed'
exit 1
EOF
chmod +x "$WORK_DIR/check-updates.sh"
for context in direct scheduler; do
  if [[ "$context" == scheduler ]]; then
    context_env=(RUN_FROM_CRON=true)
  else
    context_env=()
  fi
  if output=$(env "${context_env[@]}" UU_LOCAL_FILES="$WORK_DIR" \
      UU_CHECK_JOB_EXECUTION=true "$ROOT_DIR/ultimate-updater" check 2>&1); then
    context_rc=0
  else
    context_rc=$?
  fi
  [[ "$context_rc" -eq 10 ]]
  grep -Fq 'CHECK all systems completed with warnings' <<<"$output"
done

hard_unit=ultimate-updater-check-all-systems-hard
write_running "$hard_unit" all-systems
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" bash "$ROOT_DIR/job-runner.sh" run-check \
  "$hard_unit" all-systems "$WORK_DIR/hard-cli" all; then
  echo 'hard aggregate failure was converted to success' >&2
  exit 1
fi
grep -Fxq 'state=failed' "$WORK_DIR/jobs/$hard_unit.state"
grep -Fxq 'exit_code=1' "$WORK_DIR/jobs/$hard_unit.state"

single_unit=ultimate-updater-check-single-target-warning
write_running "$single_unit" 211
if UU_JOB_STATE_DIR="$WORK_DIR/jobs" bash "$ROOT_DIR/job-runner.sh" run-check \
  "$single_unit" 211 "$WORK_DIR/warning-cli" target; then
  echo 'single-target warning code was accepted as a warning' >&2
  exit 1
fi
grep -Fxq 'state=failed' "$WORK_DIR/jobs/$single_unit.state"

status_file="$WORK_DIR/status.json"
cat > "$status_file" <<'EOF'
{"targets":[{"id":"external-linux","check_status":"offline","error":{"code":"SSH_UNREACHABLE"}}]}
EOF
eval "$(sed -n '/^status_has_target_failures()/,/^run_check()/p' "$ROOT_DIR/ultimate-updater" | sed '$d')"
# shellcheck disable=SC2034 # consumed by the functions loaded from the CLI.
STATUS_FILE="$status_file"
# shellcheck disable=SC2034 # consumed by the functions loaded from the CLI.
CHECK_WARNING_RC=10
if classify_collection_result 1; then
  echo 'target failure was classified as success' >&2
  exit 1
else
  classification=$?
fi
[[ "$classification" -eq 10 ]]
: > "$status_file.hard-failure"
if classify_collection_result 1; then
  echo 'hard failure marker was ignored' >&2
  exit 1
else
  classification=$?
fi
[[ "$classification" -eq 1 ]]

python3 - "$ROOT_DIR" <<'PY'
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    runner = Path(directory) / "runner"
    runner.write_text(
        "#!/usr/bin/env python3\n"
        "print('\\t'.join(['ultimate-updater-check-warning', 'all-systems', 'completed_with_warnings', '2026-08-23T00:00:00Z', '2026-08-23T00:00:01Z', '0', 'check', '', '']))\n",
        encoding="utf-8",
    )
    runner.chmod(0o755)
    sys.path.insert(0, str(root / "web-ui"))
    import server

    class Fake:
        server = SimpleNamespace(job_runner=runner)
        def run_command(self, args, timeout=15):
            return subprocess.run(args, capture_output=True, text=True, check=False)

    row = server.StatusHandler.jobs(Fake())[0]
    assert row["state"] == "completed_with_warnings", row
print("server-side warning state: PASS")
PY

echo 'check warning status tests: PASS'
