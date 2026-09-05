#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
JOBS="$WORK_DIR/jobs"
mkdir -p "$JOBS"

write_state() {
  local unit="$1" state="$2" started="$3"
  local finished="" exit_code=1
  [[ "$state" == running ]] || finished="$started"
  [[ "$state" == completed ]] && exit_code=0
  cat > "$JOBS/$unit.state" <<EOF
schema_version=1
unit=$unit
target=all-systems
state=$state
started_at=$started
finished_at=$finished
exit_code=$exit_code
type=check
message=
source=
EOF
}

for number in $(seq -w 1 55); do
  write_state "ultimate-updater-check-old-$number" completed "2020-01-01T00:00:${number}Z"
done
write_state ultimate-updater-check-running-a running "2999-01-01T00:00:00Z"
write_state ultimate-updater-check-running-b running "2999-01-01T00:00:01Z"

output=$(UU_JOB_STATE_DIR="$JOBS" UU_MAX_COMPLETED_JOBS=50 bash "$ROOT_DIR/job-runner.sh" list)
completed_count=$(find "$JOBS" -maxdepth 1 -name '*.state' -print0 | xargs -0 grep -l '^state=completed$' | wc -l)
running_count=$(find "$JOBS" -maxdepth 1 -name '*.state' -print0 | xargs -0 grep -l '^state=running$' | wc -l)
[[ "$completed_count" -eq 50 ]]
[[ "$running_count" -eq 2 ]]
grep -Fq 'ultimate-updater-check-running-a' <<< "$output"
grep -Fq 'ultimate-updater-check-running-b' <<< "$output"
[[ $(grep -c '^ultimate-updater-check-' <<< "$output") -eq 52 ]]
[[ ! -e "$JOBS/ultimate-updater-check-old-01.state" ]]
[[ ! -e "$JOBS/ultimate-updater-check-old-05.state" ]]
[[ -e "$JOBS/ultimate-updater-check-old-06.state" ]]

# The web API applies its own response limit instead of asking the browser to
# discard an unbounded list. Running jobs remain included in the response.
python3 - "$ROOT_DIR" <<'PY'
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    runner = Path(directory) / "runner"
    lines = []
    for number in range(25):
        lines.append("\t".join([
            f"ultimate-updater-check-{number:02d}", "all-systems", "completed",
            f"2026-08-18T00:{number:02d}:00Z", f"2026-08-18T00:{number:02d}:01Z", "0", "check", "", "",
        ]))
    lines.append("\t".join([
        "ultimate-updater-check-running", "all-systems", "running",
        "2020-01-01T00:00:00Z", "", "", "check", "", "",
    ]))
    runner.write_text("#!/usr/bin/env python3\nprint(" + repr("\n".join(lines)) + ")\n", encoding="utf-8")
    runner.chmod(0o755)
    sys.path.insert(0, str(root / "web-ui"))
    import server

    class Fake:
        server = SimpleNamespace(job_runner=runner)
        def run_command(self, args, timeout=15):
            return subprocess.run(args, capture_output=True, text=True, check=False)

    rows = server.StatusHandler.jobs(Fake())
    assert len(rows) == 20, len(rows)
    assert any(row["unit"] == "ultimate-updater-check-running" for row in rows)
    assert rows[0]["unit"] == "ultimate-updater-check-24", rows[0]
print("web API job limit: PASS")
PY

echo 'job retention and API limit tests: PASS'
