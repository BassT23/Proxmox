#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/local"
printf 'IN_HEADLESS_MODE="false"\n' > "$WORK_DIR/local/update.conf"

# Exercise the same policy function used by the CLI without starting a job.
awk '/^configured_headless\(\)/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/ultimate-updater" > "$WORK_DIR/policy.sh"
awk '/^interactive_requested\(\)/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/ultimate-updater" >> "$WORK_DIR/policy.sh"

policy() {
  env -u UU_NONINTERACTIVE -u UU_JOB_INTERACTIVE \
    LOCAL_FILES="$WORK_DIR/local" UU_JOB_INTERACTIVE=true \
    bash -c 'source "$1"; interactive_requested' _ "$WORK_DIR/policy.sh"
}

policy

if env UU_NONINTERACTIVE=true UU_JOB_INTERACTIVE=true LOCAL_FILES="$WORK_DIR/local" \
    bash -c 'source "$1"; interactive_requested' _ "$WORK_DIR/policy.sh"; then
  echo 'noninteractive override unexpectedly selected interactive mode' >&2
  exit 1
fi

printf 'IN_HEADLESS_MODE="true"\n' > "$WORK_DIR/local/update.conf"
if env -u UU_NONINTERACTIVE UU_JOB_INTERACTIVE=true LOCAL_FILES="$WORK_DIR/local" \
    bash -c 'source "$1"; interactive_requested' _ "$WORK_DIR/policy.sh"; then
  echo 'permanent headless mode unexpectedly selected interactive mode' >&2
  exit 1
fi

printf 'IN_HEADLESS_MODE="false"\n' > "$WORK_DIR/local/update.conf"
if env RUN_FROM_CRON=true LOCAL_FILES="$WORK_DIR/local" \
    bash -c 'source "$1"; interactive_requested' _ "$WORK_DIR/policy.sh"; then
  echo 'scheduler/noninteractive policy unexpectedly selected interactive mode' >&2
  exit 1
fi

grep -Fq 'Environment=UU_NONINTERACTIVE=true' "$ROOT_DIR/web-ui/server.py"
grep -Fq '"UU_NONINTERACTIVE": "true"' "$ROOT_DIR/web-ui/server.py"
grep -Fq -- '--setenv=UU_NONINTERACTIVE=true' "$ROOT_DIR/job-runner.sh"
grep -Fq 'UU_NONINTERACTIVE=true' "$ROOT_DIR/update.sh"

echo 'mode selection tests: PASS'
