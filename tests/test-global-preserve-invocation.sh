#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

make_fixture() {
  local dir="$1" runner="$2"
  mkdir -p "$dir/jobs/remote" "$dir/files"
  cp "$runner" "$dir/files/job-runner.sh"
  cp "$ROOT_DIR/status-model.sh" "$dir/files/status-model.sh"
  cat >"$dir/files/update.conf" <<'EOF'
EMAIL_ONLY_ERROR="true"
EOF
  cat >"$dir/status.json" <<'JSON'
{"schema_version":1,"generated_at":"2026-09-25T10:00:00Z","targets":[
  {"id":"ext01","type":"external","check_status":"ok","reachable":true,
   "updates":{"available":1},"last_update":{"status":"unknown","timestamp":null}}
]}
JSON
  cat >"$dir/update.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
python3 - "${UU_STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
payload["generated_at"] = "2026-09-25T10:00:01Z"
target = payload["targets"][0]
target["updates"]["available"] = 0
target["last_update"] = {
    "status": "success", "timestamp": "2026-09-25T10:00:01Z",
    "exit_code": 0, "pending_before": 1
}
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output)
    output.write("\n")
PY
EOF
  chmod +x "$dir/update.sh"
  cat >"$dir/files/ultimate-updater" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == check ]]
python3 - "${UU_STATUS_MODEL_FILE:-$LOCAL_FILES/status.json}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    payload = json.load(source)
if os.environ.get("CHECK_BEFORE"):
    with open(os.environ["CHECK_BEFORE"], "w", encoding="utf-8") as output:
        json.dump(payload, output)
payload["generated_at"] = "2026-09-25T10:00:02Z"
target = payload["targets"][0]
target["updates"]["available"] = 0
target["last_update"] = {"status": "unknown", "timestamp": None}
with open(path, "w", encoding="utf-8") as output:
    json.dump(payload, output)
    output.write("\n")
PY
EOF
  chmod +x "$dir/files/ultimate-updater"
cat >"$dir/jobs/ultimate-updater-update-all-systems-test.state" <<'EOF'
schema_version=1
unit=ultimate-updater-update-all-systems-test
target=all-systems
state=running
started_at=2026-09-25T10:00:00Z
EOF
}

run_case() {
  local name="$1" runner="$2" expected="$3"
  local dir="$WORK_DIR/$name"
  make_fixture "$dir" "$runner"
  set +e
  UU_JOB_STATE_DIR="$dir/jobs" \
  UU_LOCAL_FILES="$dir/files" \
  UU_STATUS_MODEL_FILE="$dir/status.json" \
  UU_STATUS_MODEL_SCRIPT="$dir/files/status-model.sh" \
  UU_UPDATE_CONFIG_FILE="$dir/files/update.conf" \
  UU_CHECK_CLI="$dir/files/ultimate-updater" \
  CHECK_BEFORE="$dir/before-check.json" \
  UU_EXTERNAL_LIFECYCLE_TRACE=true \
  UU_EXTERNAL_LIFECYCLE_TRACE_FILE="$dir/trace.jsonl" \
    bash "$dir/files/job-runner.sh" run-global \
      ultimate-updater-update-all-systems-test "$dir/update.sh" >"$dir/output" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    cat "$dir/output" >&2
    return 1
  fi
  EXPECTED="$expected" STATUS="$dir/status.json" TRACE="$dir/trace.jsonl" \
    python3 - <<'PY'
import json
import os

with open(os.environ["STATUS"], encoding="utf-8") as source:
    target = json.load(source)["targets"][0]
assert target["last_update"]["status"] == os.environ["EXPECTED"]
events = [json.loads(line) for line in open(os.environ["TRACE"], encoding="utf-8")]
checkpoints = [event["checkpoint"] for event in events]
if os.environ["EXPECTED"] == "unknown":
    assert "before_preserve" not in checkpoints
    raise SystemExit(0)
required = ["before_post_check", "after_post_check", "before_preserve",
            "after_preserve", "before_update_notification"]
positions = [checkpoints.index(item) for item in required]
assert positions == sorted(positions), checkpoints
if os.environ["EXPECTED"] == "success":
    event = events[positions[3]]
    assert event["last_update_status"] == "success"
    assert event["pending_before"] == 1
PY
}

# The old runner demonstrates the skipped preserve branch: the full refresh
# replaces the current-run result with unknown because status-model.sh is not
# sourced into the runner shell.
BASE_RUNNER="$WORK_DIR/base-job-runner.sh"
git -C "$ROOT_DIR" show e02a34d:job-runner.sh >"$BASE_RUNNER"
run_case pre-fix "$BASE_RUNNER" unknown
run_case fixed "$ROOT_DIR/job-runner.sh" success

echo 'Global preserve invocation regression: PASS'
