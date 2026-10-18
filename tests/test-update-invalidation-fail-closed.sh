#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2329 # Runtime fixture and intentionally inert mutator mocks.
# Verify that every local mutation path has a mandatory invalidation gate.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Execute the production gate with the invalidation helper deliberately
# absent.  The mocked mutators must remain untouched.
sed -n '/^REQUIRE_PACKAGE_DATA_INVALIDATION() {/,/^MARK_PACKAGE_DATA_MUTATION_COMPLETE() {/p' \
  "$ROOT_DIR/update.sh" | sed '$d' > "$WORK_DIR/require-gate.sh"
source "$WORK_DIR/require-gate.sh"
UPDATE_FAILURE=false
MUTATION_CALLS=0
pveupdate() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
apt-get() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
pct() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
qm() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
RUN_PCT_COMMAND() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
RUN_UPDATE_COMMAND() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
VM_BACKUP() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
unset -f MARK_PACKAGE_DATA_INVALIDATED 2>/dev/null || true
if REQUIRE_PACKAGE_DATA_INVALIDATION; then
  echo 'missing invalidation helper unexpectedly passed the gate' >&2
  exit 1
fi
[[ "$UPDATE_FAILURE" == true ]]
[[ "$MUTATION_CALLS" -eq 0 ]]

# A present helper that rejects the target is equally fail-closed: the host
# mutation command must not be reached.
awk '/^UPDATE_HOST_ITSELF \(\) \{/{capture=1} capture{print} capture && /^}/ {exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/host-update.sh"
source "$WORK_DIR/host-update.sh"
UPDATE_FAILURE=false
MUTATION_CALLS=0
MARK_PACKAGE_DATA_INVALIDATED() { return 1; }
pveupdate() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
RUN_UPDATE_COMMAND() { MUTATION_CALLS=$((MUTATION_CALLS + 1)); }
if UPDATE_HOST_ITSELF; then
  echo 'failed invalidation unexpectedly allowed host mutation' >&2
  exit 1
fi
[[ "$UPDATE_FAILURE" == true ]]
[[ "$MUTATION_CALLS" -eq 0 ]]

function_body() {
  local function_name="$1"
  awk -v name="$function_name" '
    $0 ~ "^" name " \\(\\) \\{" {capture=1}
    capture {print}
    capture && /^}/ {exit}
  ' "$ROOT_DIR/update.sh"
}

assert_gate_precedes_mutation() {
  local function_name="$1" mutation_pattern="$2" body gate_line mutation_line
  body=$(function_body "$function_name")
  grep -Fq 'REQUIRE_PACKAGE_DATA_INVALIDATION' <<<"$body"
  gate_line=$(grep -nF 'REQUIRE_PACKAGE_DATA_INVALIDATION' <<<"$body" | head -n1 | cut -d: -f1)
  mutation_line=$(grep -nE "$mutation_pattern" <<<"$body" | head -n1 | cut -d: -f1)
  [[ -n "$mutation_line" ]]
  (( gate_line < mutation_line ))
}

assert_gate_precedes_mutation UPDATE_HOST_ITSELF 'pveupdate|RUN_UPDATE_COMMAND'
assert_gate_precedes_mutation CONTAINER_UPDATE_START 'RUN_PROXMOX_COMMAND pct start'
assert_gate_precedes_mutation UPDATE_CONTAINER 'RUN_PCT_COMMAND'
assert_gate_precedes_mutation VM_UPDATE_START 'RUN_PROXMOX_COMMAND qm start'
assert_gate_precedes_mutation UPDATE_VM 'VM_BACKUP|RUN_QM_COMMAND|RUN_SSH_COMMAND'

# External-APT has its own shell boundary; its missing-helper branch must
# explicitly abort rather than fall through to remote_update.
external_body=$(awk '/^update_target\(\) \{/{capture=1} capture{print} capture && /^}/ {exit}' \
  "$ROOT_DIR/external-apt.sh")
grep -Fq 'declare -f STATUS_MODEL_INVALIDATE_PACKAGE_DATA' <<<"$external_body"
grep -Fq 'External update blocked: package freshness invalidation is unavailable.' <<<"$external_body"
grep -Fq 'return 43' <<<"$external_body"

# No supported path may silently turn a missing helper into a successful
# update.  The only function-existence check is the mandatory gate itself.
if grep -nE 'if declare -f MARK_PACKAGE_DATA_INVALIDATED|declare -f MARK_PACKAGE_DATA_INVALIDATED .*&&' \
  "$ROOT_DIR/update.sh"; then
  echo 'optional package invalidation guard remains in update.sh' >&2
  exit 1
fi

printf '%s\n' 'update invalidation fail-closed tests: PASS'
