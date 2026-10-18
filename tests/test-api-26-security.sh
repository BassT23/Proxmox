#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/bin" "$WORK_DIR/jobs" "$WORK_DIR/local/scripts.d/986"
cat > "$WORK_DIR/local/status.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"986","type":"vm","node":"test-node",
"package_data_invalidated":true,"package_mutation_in_progress":true,
"package_mutation_generation":1,
"package_mutation_operation_id":"uu-op-fixture-20261017T120000-1"}]}
JSON

printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/update.sh"
chmod 750 "$WORK_DIR/update.sh"
cat > "$WORK_DIR/bin/systemd-run" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$SYSTEMD_ARGS_FILE"
printf 'Running as unit: fixture-unit\n'
EOF
chmod 750 "$WORK_DIR/bin/systemd-run"

# Exercise the real job-runner start path.  Only systemd-run is mocked; no
# service, guest, package manager, or Proxmox command is available.
awk '/Starting update jobs requires root/ { print "  :"; next } { print }' \
  "$ROOT_DIR/job-runner.sh" > "$WORK_DIR/job-runner.sh"
chmod 750 "$WORK_DIR/job-runner.sh"
SYSTEMD_ARGS_FILE="$WORK_DIR/api.args" UU_JOB_STATE_DIR="$WORK_DIR/jobs" \
  UU_API_ACTION=update UU_NONINTERACTIVE=true UU_API_REBOOT_ALLOWED=false \
  UU_PACKAGE_MUTATION_OPERATION_ID=uu-op-fixture-20261017T120000 \
  UU_API_EXPECTED_TARGET_ID=986 UU_API_EXPECTED_TARGET_KIND=vm \
  UU_API_EXPECTED_TARGET_NODE=test-node UU_API_EXPECTED_TARGET_LOCAL=true \
  PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/job-runner.sh" start \
  "$WORK_DIR/update.sh" 986 >/dev/null
grep -Fqx -- '--setenv=UU_API_ACTION=update' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_NONINTERACTIVE=true' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_API_REBOOT_ALLOWED=false' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_PACKAGE_MUTATION_OPERATION_ID=uu-op-fixture-20261017T120000' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_API_EXPECTED_TARGET_ID=986' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_API_EXPECTED_TARGET_KIND=vm' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_API_EXPECTED_TARGET_NODE=test-node' "$WORK_DIR/api.args"
grep -Fqx -- '--setenv=UU_API_EXPECTED_TARGET_LOCAL=true' "$WORK_DIR/api.args"

# Exercise the real remote command construction with SSH/SCP mocked.  The
# final command is captured and never sent to a network endpoint.
cat > "$WORK_DIR/bin/ssh" <<'EOF'
#!/bin/sh
last=
for arg do last=$arg; done
printf '%s\n' "$last" >> "$REMOTE_COMMANDS"
case "$last" in
  *'exec /usr/bin/env'*) printf 'Update job started\nTarget: 986\nJob: ultimate-updater-update-986-fixture\n' ;;
esac
EOF
cat > "$WORK_DIR/bin/scp" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$WORK_DIR/remote-job-runner" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 750 "$WORK_DIR/bin/ssh" "$WORK_DIR/bin/scp" "$WORK_DIR/remote-job-runner"
REMOTE_COMMANDS="$WORK_DIR/remote.commands" UU_API_ACTION=update UU_NONINTERACTIVE=true \
  UU_API_EXPECTED_TARGET_ID=986 UU_API_EXPECTED_TARGET_KIND=vm \
  UU_API_EXPECTED_TARGET_NODE=test-node UU_API_EXPECTED_TARGET_LOCAL=true \
  PATH="$WORK_DIR/bin:$PATH" bash -c '
    UU_LOCAL_FILES="$2/local"; STATUS_FILE="$2/local/status.json"
    source "$1/ultimate-updater" help >/dev/null 2>&1
    JOB_RUNNER="$2/remote-job-runner" UPDATE_SCRIPT="$2/update.sh"
    REMOTE_NODE_ARGS=() REMOTE_NODE_USER=root REMOTE_NODE_PORT=22
    REMOTE_UPDATE_OPERATION_ID=uu-op-fixture-20261017T120000-1 remote_update_job guest 986 test-node 192.0.2.99 uu-op-fixture-20261017T120000-1 vm
  ' _ "$ROOT_DIR" "$WORK_DIR" >/dev/null
grep -Fq 'UU_API_ACTION=update' "$WORK_DIR/remote.commands"
grep -Fq 'UU_NONINTERACTIVE=true' "$WORK_DIR/remote.commands"
grep -Fq 'UU_API_REBOOT_ALLOWED=false' "$WORK_DIR/remote.commands"
grep -Fq 'UU_PACKAGE_MUTATION_OPERATION_ID=uu-op-fixture-20261017T120000' "$WORK_DIR/remote.commands"
grep -Fq 'UU_API_EXPECTED_TARGET_ID=986' "$WORK_DIR/remote.commands"
grep -Fq 'UU_API_EXPECTED_TARGET_KIND=vm' "$WORK_DIR/remote.commands"
grep -Fq 'UU_API_EXPECTED_TARGET_NODE=test-node' "$WORK_DIR/remote.commands"
grep -Fq 'UU_API_EXPECTED_TARGET_LOCAL=remote' "$WORK_DIR/remote.commands"

# A syntactically valid operation ID is not sufficient by itself.  A direct
# remote dispatch without the exact active controller reservation must fail
# before SSH is reached.
cat > "$WORK_DIR/local/unreserved.json" <<'JSON'
{"schema_version":1,"targets":[{"id":"986","type":"vm","node":"test-node",
"package_data_invalidated":false,"package_mutation_in_progress":false,
"package_mutation_generation":1}]}
JSON
: > "$WORK_DIR/unreserved.commands"
set +e
REMOTE_COMMANDS="$WORK_DIR/unreserved.commands" PATH="$WORK_DIR/bin:$PATH" bash -c '
  UU_LOCAL_FILES="$2/local"
  source "$1/ultimate-updater" help >/dev/null 2>&1
  STATUS_FILE="$2/local/unreserved.json"
  REMOTE_NODE_ARGS=() REMOTE_NODE_USER=root REMOTE_NODE_PORT=22
  remote_update_job guest 986 test-node 192.0.2.99 uu-op-fixture-20261017T120000-1 vm
' _ "$ROOT_DIR" "$WORK_DIR" >/dev/null 2>&1
unreserved_rc=$?
set -e
[[ $unreserved_rc -eq 46 ]]
[[ ! -s "$WORK_DIR/unreserved.commands" ]]

# Ordinary noninteractive jobs retain their existing context and do not gain
# API-only controls.
SYSTEMD_ARGS_FILE="$WORK_DIR/ordinary.args" UU_JOB_STATE_DIR="$WORK_DIR/jobs-ordinary" \
  UU_NONINTERACTIVE=true PATH="$WORK_DIR/bin:$PATH" bash "$WORK_DIR/job-runner.sh" start \
  "$WORK_DIR/update.sh" 986 >/dev/null
grep -Fqx -- '--setenv=UU_NONINTERACTIVE=true' "$WORK_DIR/ordinary.args"
if grep -Fq -- '--setenv=UU_API_ACTION=' "$WORK_DIR/ordinary.args" ||
   grep -Fq -- '--setenv=UU_API_REBOOT_ALLOWED=' "$WORK_DIR/ordinary.args"; then
  echo 'ordinary job inherited API-only context' >&2
  exit 1
fi

# The optional-update helper rejects an API context before any optional path
# can be entered.
printf 'EXTRA_GLOBAL="true"\n' > "$WORK_DIR/local/update.conf"
set +e
UU_API_ACTION=update LOCAL_FILES="$WORK_DIR/local" \
  bash "$ROOT_DIR/update-extras.sh" > "$WORK_DIR/extras.out" 2>&1
extras_rc=$?
set -e
[[ $extras_rc -eq 42 ]]
grep -Fq 'API_UNSAFE_SCRIPT_PATH' "$WORK_DIR/extras.out"

# The actual target-scoped guard distinguishes an absent optional path from an
# active one.  The guest probe is mocked, but the production function and its
# return/error behavior are exercised.
awk '/^SCRIPT_ONLY_FILES \(\) \{/{exit} /^SCRIPT_ONLY_ENABLED \(\) \{/{copy=1} copy{print}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/api-guard.sh"
cat > "$WORK_DIR/guard-harness.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
LOCAL_FILES="$1/local"
USER_SCRIPTS="$LOCAL_FILES/scripts.d"
EXTRA_GLOBAL=true
EXTRA_IN_HEADLESS=true
UU_API_ACTION=update
ERROR() { return 0; }
RUN_PCT_COMMAND() { printf '%s\n' "${PROBE_RESULT:-safe}"; return "${PROBE_RC:-0}"; }
RUN_QEMU_COMMAND() { printf '%s\n' "${PROBE_RESULT:-safe}"; return "${PROBE_RC:-0}"; }
RUN_LOCAL_COMMAND() { printf '%s\n' "${PROBE_RESULT:-safe}"; return "${PROBE_RC:-0}"; }
RUN_SSH_COMMAND() { printf '%s\n' "${PROBE_RESULT:-safe}"; return "${PROBE_RC:-0}"; }
source "$1/api-guard.sh"

API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 986 lxc debian
[[ "$UU_API_SCRIPT_PREFLIGHT_SAFE" == true ]]

PROBE_RESULT=unsafe
set +e
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 986 lxc debian
rc=$?
set -e
[[ $rc -eq 42 ]]

PROBE_RESULT=safe
PROBE_RC=7
# A failed read-only guest probe is now an unavailable preflight, not proof of
# an unsafe script path.
set +e
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 986 lxc debian
rc=$?
set -e
[[ $rc -eq 43 ]]

PROBE_RESULT=safe
PROBE_RC=0
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 192.0.2.10 host proxmox
[[ "$UU_API_SCRIPT_PREFLIGHT_SAFE" == true ]]
PROBE_RESULT=unsafe
set +e
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 192.0.2.10 host proxmox
rc=$?
set -e
[[ $rc -eq 42 ]]

mkdir -p "$USER_SCRIPTS/986"
touch "$USER_SCRIPTS/986/.script-only"
set +e
API_UPDATE_REJECT_UNSAFE_SCRIPT_PATH 986 lxc debian
rc=$?
set -e
[[ $rc -eq 42 ]]
EOF
chmod 750 "$WORK_DIR/guard-harness.sh"
PROBE_RESULT=safe bash "$WORK_DIR/guard-harness.sh" "$WORK_DIR"

echo 'API-2.6 security context tests: PASS'
