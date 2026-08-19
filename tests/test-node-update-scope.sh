#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# The node action must explicitly carry a host-only scope into both local and
# remote jobs.  update-all and single-target dispatch remain separate paths.
grep -Fq "UU_UPDATE_SCOPE=host \"\$JOB_RUNNER\" start \"\$UPDATE_SCRIPT\" host" "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_LOCAL_FILES=%q UU_REMOTE_WORK_DIR=%q UU_UPDATE_SCOPE=host' "$ROOT_DIR/ultimate-updater"
grep -Fq "\"\${UU_UPDATE_SCOPE:-}\" == host" "$ROOT_DIR/update.sh"
grep -Fq "\"\${UU_UPDATE_SCOPE:-}\" != host && \"\$WITH_VM\" == true" "$ROOT_DIR/update.sh"
grep -Fq "systemd_env+=(\"--setenv=UU_UPDATE_SCOPE=host\")" "$ROOT_DIR/job-runner.sh"
grep -Fq 'remote_update_dir="/tmp/ultimate-updater-update-node-' "$ROOT_DIR/ultimate-updater"
grep -Fq 'scp -q "${ssh_args[@]}"' "$ROOT_DIR/ultimate-updater"
grep -Fq 'UU_LOCAL_FILES=%q UU_REMOTE_WORK_DIR=%q UU_UPDATE_SCOPE=host' "$ROOT_DIR/ultimate-updater"
grep -Fq 'LOCAL_FILES="${UU_LOCAL_FILES:-/etc/ultimate-updater}"' "$ROOT_DIR/update.sh"
grep -Fq 'CHECK_SCRIPT="${UU_CHECK_SCRIPT:-${UU_LOCAL_FILES:-/etc/ultimate-updater}/check-updates.sh}"' "$ROOT_DIR/job-runner.sh"

if [[ "$EUID" -eq 0 ]]; then
  # Verify that the job boundary exports the scope to systemd rather than
  # only keeping it in the caller's shell environment.
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs"
  cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$UU_SCOPE_CAPTURE"
exit 0
EOF
  chmod +x "$WORK_DIR/bin/systemd-run"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK_DIR/update.sh"
  chmod +x "$WORK_DIR/update.sh"
  UU_SCOPE_CAPTURE="$WORK_DIR/systemd-run.args" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
    PATH="$WORK_DIR/bin:$PATH" UU_UPDATE_SCOPE=host \
    "$ROOT_DIR/job-runner.sh" start "$WORK_DIR/update.sh" host >/dev/null
  grep -Fq -- '--setenv=UU_UPDATE_SCOPE=host' "$WORK_DIR/systemd-run.args"
fi

echo 'node update host-only scope tests: PASS'
