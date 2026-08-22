#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Split values are only user-facing when the preceding target summary is
# emitted.  Unconditional zero/zero lines were previously left behind for
# healthy hosts, LXCs, and VMs without a visible target header.
if grep -Fq 'echo -e "Normal updates:' "$ROOT_DIR/check-updates.sh" ||
   grep -Fq 'echo -e "Security updates:' "$ROOT_DIR/check-updates.sh"; then
  echo 'raw unscoped update lines remain in check output' >&2
  exit 1
fi
grep -Fq 'TAG_OUTPUT=false STATUS_MODEL_NODE=' "$ROOT_DIR/check-updates.sh"

# The explicit diagnostic gate is part of the output contract: DEBUG=false is
# clean, while DEBUG=true retains the technical remote details.
grep -Fq 'if [[ "${DEBUG:-false}" == true && "$remote_diagnostics_found" == true ]]; then' \
  "$ROOT_DIR/check-updates.sh"
grep -Fq '[[ "${DEBUG:-false}" == true ]] || return 0' "$ROOT_DIR/check-updates.sh"

printf '%s\n' 'output summary regression tests: PASS'
