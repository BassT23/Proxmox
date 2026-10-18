#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the actual downstream global VM dispatch.  Proxmox and guest-check
# commands are local mocks; no qm/pct/SSH/systemd action can reach a host.
awk '
  /^API_CHECK_TARGET_IDENTITY_GUARD\(\)/ {copy=1}
  copy {print}
  copy && /^}/ {exit}
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/api-identity.sh"
awk '
  /^VM_CHECK_START \(\)/ {copy=1}
  copy {print}
  /^# VM Check$/ {if (copy) exit}
' "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/vm-dispatch.sh"
awk '
  /^CHECK_VM_LIFECYCLE \(\)/ {copy=1}
  copy {print}
  /^# VM Check$/ {if (copy) exit}
' "$ROOT_DIR/check-updates.sh" >> "$WORK_DIR/vm-dispatch.sh"

cat > "$WORK_DIR/dispatch-harness.sh" <<'HARNESS'
#!/bin/bash
set -euo pipefail

source "$1/api-identity.sh"
source "$1/vm-dispatch.sh"

LOCAL_FILES="$1"
ONLY=""
EXCLUDED=""
USE_INTERNAL_TARGET_SELECTION=false
RUNNING_VM=true
STOPPED_VM=false
PAUSED_VM=false
VM_START_DELAY=0
STATUS_MODEL_NODE=test-node
STATUS_MODEL_GUEST_NAME=""
BL='' OR='' RD='' GN='' CL=''

SANITIZE_NUMBER() { printf '%s' "$1"; }
QGA_CONFIG_ENABLED() { return 0; }
guest_id_matches() { return 1; }
STATUS_MODEL_RECORD() { :; }
CHECK_VM() { dispatched+=("$1"); }

qm() {
  case "${1:-}" in
    list)
      # VM_CHECK_START consumes the first column from this fixture.
      printf 'VMID NAME STATUS\n108\n111\n112\n'
      ;;
    config)
      printf 'ostype: l26\nname: fixture-%s\n' "$2"
      ;;
    status)
      printf 'status: running\n'
      ;;
    *)
      return 1
      ;;
  esac
}

# The global API context has no single target identity.  Every current VM
# from the real VM dispatch loop must still be checked, without the single
# target guard demanding a missing expected VMID.
UU_API_ACTION=check-all
unset UU_API_EXPECTED_TARGET_ID UU_API_EXPECTED_TARGET_KIND \
  UU_API_EXPECTED_TARGET_NODE UU_API_EXPECTED_TARGET_LOCAL
dispatched=()
VM_CHECK_START
[[ "${dispatched[*]}" == '108 111 112' ]]

# The same downstream loop must remain fail-closed for a real API single
# check when its expected identity is absent.
UU_API_ACTION=check
dispatched=()
set +e
VM_CHECK_START
single_rc=$?
set -e
[[ "$single_rc" -ne 0 ]]
[[ -z "${dispatched[*]}" ]]

printf 'global API VM dispatch: PASS\n'
HARNESS
chmod 750 "$WORK_DIR/dispatch-harness.sh"
bash "$WORK_DIR/dispatch-harness.sh" "$WORK_DIR"

# Exercise the real job-runner context boundary.  Only systemd-run is mocked;
# the fixture does not execute the resulting worker.
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs"
cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$SYSTEMD_ARGS_FILE"
printf 'Running as unit: fixture-unit\n'
EOF
chmod 750 "$WORK_DIR/bin/systemd-run"
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/cli"
chmod 750 "$WORK_DIR/cli"

awk '/Starting check jobs requires root/ { print "  :"; next } { print }' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/job-runner.sh"
chmod 750 "$WORK_DIR/job-runner.sh"
SYSTEMD_ARGS_FILE="$WORK_DIR/check.args" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_API_ACTION=check-all UU_JOB_SOURCE=initial-inventory UU_NONINTERACTIVE=true \
  PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/job-runner.sh" start-check \
  all-systems "$WORK_DIR/cli" all >/dev/null
grep -Fqx -- '--setenv=UU_API_ACTION=check-all' "$WORK_DIR/check.args"
grep -Fqx -- '--setenv=UU_JOB_SOURCE=initial-inventory' "$WORK_DIR/check.args"
grep -Fqx -- '--setenv=UU_NONINTERACTIVE=true' "$WORK_DIR/check.args"
if grep -Fq -- '--setenv=UU_API_EXPECTED_TARGET_ID=' "$WORK_DIR/check.args"; then
  echo 'global check propagated a single-target identity' >&2
  exit 1
fi

# Cluster remote workers receive the global marker too; the worker must not
# silently downgrade an API check-all to an ordinary or single-target check.
grep -Fq "remote_status_env=\" UU_API_ACTION=check-all\$remote_status_env\"" \
  "$ROOT_DIR/check-updates.sh"

echo 'API global-check context regression: PASS'
