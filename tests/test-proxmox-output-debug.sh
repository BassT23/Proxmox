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

# Remote target diagnostics are debug-only; the structured status model keeps
# the actual child error available for the final summary and notifications.
awk '/^REMOTE_STATUS_FAILURE_SUMMARY \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/remote-failure-summary.sh"
# shellcheck source=/dev/null
source "$WORK_DIR/remote-failure-summary.sh"
cat > "$WORK_DIR/remote-status.json" <<'JSON'
{"targets":[{"id":"guest:211","name":"iobroker","type":"lxc","error":{"code":"CHECK_COMMAND_FAILED","message":"apt-get update failed for LXC 211"}}]}
JSON
if DEBUG=false output=$(REMOTE_STATUS_FAILURE_SUMMARY "$WORK_DIR/remote-status.json" node2); then
  [[ -z "$output" ]]
else
  exit 1
fi
DEBUG=true output=$(REMOTE_STATUS_FAILURE_SUMMARY "$WORK_DIR/remote-status.json" node2)
grep -Fq 'Remote check target guest:211 (iobroker) failed:' <<<"$output"

# QGA readiness progress is also debug-only.  The readiness result itself is
# still returned to the caller, which records a final QGA_NOT_READY error.
awk '/^WAIT_FOR_QGA \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/wait-for-qga.sh"
# shellcheck source=/dev/null
source "$WORK_DIR/wait-for-qga.sh"
timeout() { shift; "$@"; }
qm() { return 0; }
# shellcheck disable=SC1007,SC2034 # sourced functions consume these test values.
OR= GR= RD= CL=
# shellcheck disable=SC2034 # consumed by the sourced readiness function.
VM=971
DEBUG=false
WAIT_FOR_QGA >"$WORK_DIR/qga-normal"
[[ ! -s "$WORK_DIR/qga-normal" ]]
DEBUG=true
WAIT_FOR_QGA >"$WORK_DIR/qga-debug"
grep -Fq 'Waiting for QEMU Guest Agent on VM 971' "$WORK_DIR/qga-debug"
grep -Fq 'QEMU Guest Agent ready after' "$WORK_DIR/qga-debug"

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
