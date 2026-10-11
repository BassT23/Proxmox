#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs-false" "$WORK_DIR/jobs-true"
cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${UU_SYSTEMD_ARGS_FILE:?}"
exit 0
EOF
cat > "$WORK_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$WORK_DIR/bin/systemd" <<'EOF'
#!/usr/bin/env bash
printf 'systemd %s\n' "${UU_TEST_SYSTEMD_VERSION:-253}"
EOF
cat > "$WORK_DIR/check.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 750 "$WORK_DIR/bin/systemd-run" "$WORK_DIR/bin/systemctl" "$WORK_DIR/bin/systemd" "$WORK_DIR/check.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo 'job runner Proxmox journal filter gating: PASS (runtime fixture skipped: root required)'
  exit 0
fi

cat > "$WORK_DIR/update.conf" <<'EOF'
DEBUG="false"
EOF

run_start() {
  local state_dir="$1" args_file="$2" systemd_version="$3"
  UU_SYSTEMD_ARGS_FILE="$args_file" \
    UU_TEST_SYSTEMD_VERSION="$systemd_version" \
    UU_JOB_STATE_DIR="$state_dir" UU_UPDATE_CONFIG_FILE="$WORK_DIR/update.conf" \
    PATH="$WORK_DIR/bin:$PATH" "$ROOT_DIR/job-runner.sh" \
    start-check 910 "$WORK_DIR/check.sh" target >/dev/null
}

run_start "$WORK_DIR/jobs-false" "$WORK_DIR/false.args" 253
grep -Fq -- '--property=LogFilterPatterns=~^<root@pam>' "$WORK_DIR/false.args"
grep -Fq -- '--property=LogFilterPatterns=~^<root@pam> (snapshot|delete snapshot)' "$WORK_DIR/false.args"
grep -Fq -- '--property=LogFilterPatterns=~^(starting|shutdown)' "$WORK_DIR/false.args"
grep -Fq -- '--property=LogFilterPatterns=~^push_file' "$WORK_DIR/false.args"

sed -i 's/DEBUG="false"/DEBUG="true"/' "$WORK_DIR/update.conf"
run_start "$WORK_DIR/jobs-true" "$WORK_DIR/true.args" 253
if grep -Fq -- 'LogFilterPatterns' "$WORK_DIR/true.args"; then
  echo 'DEBUG=true unexpectedly installed journal filters' >&2
  exit 1
fi

sed -i 's/DEBUG="true"/DEBUG="false"/' "$WORK_DIR/update.conf"
run_start "$WORK_DIR/jobs-old" "$WORK_DIR/old.args" 252
if grep -Fq -- 'LogFilterPatterns' "$WORK_DIR/old.args"; then
  echo 'systemd 252 unexpectedly received LogFilterPatterns' >&2
  exit 1
fi

echo 'job runner Proxmox journal filter gating: PASS'
