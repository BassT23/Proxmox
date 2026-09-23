#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/local" "$WORK_DIR/jobs/remote" "$WORK_DIR/bin"
cp "$ROOT_DIR/job-runner.sh" "$WORK_DIR/local/job-runner.sh"
chmod 755 "$WORK_DIR/local/job-runner.sh"
touch "$WORK_DIR/local/update.conf"
printf '%s\n' '{"schema_version":1,"targets":[]}' > "$WORK_DIR/local/status.json"

cat > "$WORK_DIR/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
command="${!#}"
if [[ "$command" == if\ \[\[* ]]; then
  bash -c "$command"
else
  printf 'unexpected parser SSH command: %s\n' "$command" >&2
  exit 1
fi
SSH
chmod 755 "$WORK_DIR/bin/ssh"
export PATH="$WORK_DIR/bin:$PATH"

scp() { :; }

ssh() {
  local command='' remote_workspace arg
  for arg in "$@"; do
    if [[ "$arg" == *'bash -s'* || "$arg" == 'set -e;'* ||
      "$arg" == 'if [[ '* || "$arg" == 'mkdir -p'* ]]; then
      command="$arg"
    fi
  done
  if [[ "$command" == *'bash -s'* ]]; then
    [[ "$command" =~ UU_REMOTE_WORK_DIR=([^[:space:]]+) ]] || return 1
    remote_workspace=${BASH_REMATCH[1]}
    mkdir -p "$remote_workspace"
    printf '%s\n' '{"schema_version":1,"targets":[]}' > "$remote_workspace/status.json"
    cat >/dev/null
    return "${REMOTE_UPDATE_STATUS_FIXTURE:-0}"
  fi
  if [[ "$command" == set\ -e\;* ]]; then
    bash -c "$command"
    return 0
  fi
  if [[ "$command" == if\ \[\[* ]]; then
    bash -c "$command"
    return $?
  fi
  return 0
}

awk '/^UPDATE_HOST \(\) \{/{capture=1} capture{print} capture && /^# shellcheck disable=SC2015/{exit}' \
  "$ROOT_DIR/update.sh" | sed '$d' > "$WORK_DIR/update-host-function.sh"

# These globals are consumed by the extracted production function.
export LOCAL_FILES="$WORK_DIR/local"
export SCRIPT_DIR="$ROOT_DIR"
export UU_JOB_STATE_DIR="$WORK_DIR/jobs"
export UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote"
export START_HOST=127.0.0.1
export HOST_NODE=node2
export SSH_PORT=22
export WELCOME_SCREEN=false
export UPDATE_FAILURE=false
export USE_INTERNAL_TARGET_SELECTION=false
EFFECTIVE_HEADLESS() { return 0; }
export UU_JOB_STATE_DIR UU_REMOTE_JOB_STATE_DIR UU_LOCAL_FILES="$LOCAL_FILES"
# shellcheck source=/dev/null
source "$WORK_DIR/update-host-function.sh"

REMOTE_UPDATE_STATUS_FIXTURE=0
export REMOTE_UPDATE_STATUS_FIXTURE
UPDATE_HOST 10.0.0.2

success_state=$(find "$WORK_DIR/jobs/remote" -name '*.state' -print -quit)
[[ -n "$success_state" ]]
success_unit=$(awk -F= '$1 == "unit" {print $2; exit}' "$success_state")
success_ref="$WORK_DIR/jobs/remote/$success_unit.ref"
success_workspace=$(awk -F= '$1 == "workspace" {print $2; exit}' "$success_ref")

[[ "$(wc -l < "$success_state")" -eq 10 ]]
[[ "$(tail -c 1 "$success_state" | od -An -t x1 | tr -d ' ')" == 0a ]]
if grep -Fq 'schema_version=1nunit=' "$success_state"; then
  echo 'state contains literal n separator' >&2
  exit 1
fi
if grep -Fq $'\tn' "$success_state"; then
  echo 'state contains tab+n separator' >&2
  exit 1
fi
[[ "$(cat "$success_workspace/post-update-status.rc")" == 0 ]]
[[ "$(tail -c 1 "$success_workspace/post-update-status.rc" | od -An -t x1 | tr -d ' ')" == 0a ]]

show_success=$(UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
  UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" "$WORK_DIR/local/job-runner.sh" show "$success_unit")
grep -Fq $'\tcompleted\t' <<<"$show_success"
grep -Fq $'\t0\t' <<<"$show_success"

REMOTE_UPDATE_STATUS_FIXTURE=1
export REMOTE_UPDATE_STATUS_FIXTURE
if UPDATE_HOST 10.0.0.2; then
  echo 'expected the failed remote update fixture to return non-zero' >&2
  exit 1
fi

failed_state=$(grep -l '^state=failed$' "$WORK_DIR/jobs/remote"/*.state)
failed_unit=$(awk -F= '$1 == "unit" {print $2; exit}' "$failed_state")
failed_ref="$WORK_DIR/jobs/remote/$failed_unit.ref"
failed_workspace=$(awk -F= '$1 == "workspace" {print $2; exit}' "$failed_ref")
[[ "$(cat "$failed_workspace/post-update-status.rc")" == 1 ]]
if grep -Fq '1n' "$failed_workspace/post-update-status.rc"; then
  echo 'failure rc contains literal n suffix' >&2
  exit 1
fi

show_failed=$(UU_JOB_STATE_DIR="$WORK_DIR/jobs" UU_LOCAL_FILES="$WORK_DIR/local" \
  UU_REMOTE_JOB_STATE_DIR="$WORK_DIR/jobs/remote" "$WORK_DIR/local/job-runner.sh" show "$failed_unit")
grep -Fq $'\tfailed\t' <<<"$show_failed"
grep -Fq $'\t1\t' <<<"$show_failed"

echo 'remote finalization LF/state parser regression: PASS'
