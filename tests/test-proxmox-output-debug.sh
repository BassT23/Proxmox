#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/proxmox-fixture" <<'EOF'
#!/usr/bin/env bash
printf '<root@pam> starting task UPID:fixture\n'
printf '<root@pam> end task UPID:fixture: OK\n'
exit "${FIXTURE_RC:-0}"
EOF
chmod 750 "$WORK_DIR/proxmox-fixture"

# shellcheck source=/dev/null # the test sources the runtime path dynamically.
source "$ROOT_DIR/target-runtime.sh"

# shellcheck disable=SC2034 # DEBUG is consumed by the sourced runtime function.
DEBUG=false
if RUN_PROXMOX_COMMAND "$WORK_DIR/proxmox-fixture" >"$WORK_DIR/normal" 2>&1; then
  rc=0
else
  rc=$?
fi
[[ "$rc" -eq 0 ]]
if grep -Fq 'UPID:' "$WORK_DIR/normal"; then exit 1; fi

DEBUG=true
RUN_PROXMOX_COMMAND "$WORK_DIR/proxmox-fixture" >"$WORK_DIR/debug" 2>&1
grep -Fq 'UPID:fixture' "$WORK_DIR/debug"

# shellcheck disable=SC2034 # reset the mode for the final failure assertion.
DEBUG=false
export FIXTURE_RC=23
if RUN_PROXMOX_COMMAND "$WORK_DIR/proxmox-fixture" >"$WORK_DIR/failure" 2>&1; then
  rc=0
else
  rc=$?
fi
[[ "$rc" -eq 23 ]]
if grep -Fq 'UPID:' "$WORK_DIR/failure"; then exit 1; fi

printf 'Proxmox output debug gating: PASS\n'
