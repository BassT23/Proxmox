#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Exercise the production automatic-dispatch function with mocked check
# entry points.  This keeps the test independent of a real Proxmox host while
# still executing the actual dispatch policy from check-updates.sh.
sed -n '/^RUN_AUTOMATIC_CHECK_DISPATCH () {/,/^}$/p' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/dispatch.sh"
source "$WORK_DIR/dispatch.sh"

run_case() {
  local mode="$1" global="$2" expected="$3"
  local -a calls=()
  calls=()
  MODE="$mode" UU_GLOBAL_CHECK="$global" WITH_HOST=true WITH_LXC=true WITH_VM=true
  USE_INTERNAL_TARGET_SELECTION=false UU_CHECK_SCOPE=""
  CHECK_HOST_ITSELF() { calls+=(local-host); }
  CONTAINER_CHECK_START() { calls+=(lxc); }
  VM_CHECK_START() { calls+=(vm); }
  HOST_CHECK_START() { calls+=(cluster-host); }
  TARGET_SELECTION_ALLOWS() { return 0; }
  RUN_AUTOMATIC_CHECK_DISPATCH
  [[ "${calls[*]}" == "$expected" ]] || {
    printf 'unexpected dispatch for MODE=%s UU_GLOBAL_CHECK=%s: %s\n' \
      "$mode" "$global" "${calls[*]}" >&2
    return 1
  }
}

run_case Host true 'local-host lxc vm'
run_case Host false 'local-host lxc vm'
run_case Cluster true 'cluster-host'

# The standalone aggregate fixture reached the local check entry points, so a
# normal host/LXC/VM collection can produce records instead of a false empty
# aggregate.  Keep the separate zero-target safety regression authoritative.
printf 'standalone global check dispatch regression: PASS\n'
