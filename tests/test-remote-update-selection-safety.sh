#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell fragments.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Internal selection must fail closed if the helper is absent.  In particular,
# it must not leave the caller on the legacy EXCLUDE path.
unset USE_INTERNAL_TARGET_SELECTION TARGET_SELECTION_RUNTIME_ERROR
export USE_INTERNAL_TARGET_SELECTION=true
export UU_LOCAL_FILES="$WORK_DIR"
export LOCAL_FILES="$WORK_DIR"
export TARGET_SELECTION_SCRIPT="$WORK_DIR/missing-target-selection.sh"

# shellcheck disable=SC1091
source "$ROOT_DIR/tag-filter.sh"
ONLY="210"
EXCLUDED="210 220"
if apply_only_exclude_tags ONLY EXCLUDED; then
  printf 'missing internal selection helper was accepted\n' >&2
  exit 1
fi
[[ "${TARGET_SELECTION_RUNTIME_ERROR:-false}" == true ]]
[[ "$ONLY" == "210" && "$EXCLUDED" == "210 220" ]]

# The update loops must discard unrelated guests before applying global
# selection filters, so a single-target update cannot report VM 220 as skipped.
UPDATE_SOURCE=$(<"$ROOT_DIR/update.sh")
grep -Fq '[[ "$SINGLE_UPDATE" == true && "$CONTAINER" != "$ONLY" ]]' <<<"$UPDATE_SOURCE"
grep -Fq '[[ "$SINGLE_UPDATE" != true ]] && guest_id_matches "$EXCLUDED" "$CONTAINER"' <<<"$UPDATE_SOURCE"
grep -Fq '[[ "$SINGLE_UPDATE" == true && "$VM" != "$ONLY" ]]' <<<"$UPDATE_SOURCE"
grep -Fq '[[ "$SINGLE_UPDATE" != true ]] && guest_id_matches "$EXCLUDED" "$VM"' <<<"$UPDATE_SOURCE"

printf 'remote update selection safety tests: PASS\n'
