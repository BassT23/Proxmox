#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/tag-filter.sh"

ONLY=""
EXCLUDE="101"
apply_only_exclude_tags ONLY EXCLUDE
[[ "$ONLY" == "" && "$EXCLUDE" == "101" ]]

unset ONLY
EXCLUDE="101"
apply_only_exclude_tags ONLY EXCLUDE
[[ "$ONLY" == "" && "$EXCLUDE" == "101" ]]

ONLY="101 102"
EXCLUDE="102"
apply_only_exclude_tags ONLY EXCLUDE
[[ "$ONLY" == "101 102" && "$EXCLUDE" == "102" ]]
guest_id_matches "$ONLY" 101
if guest_id_matches "$EXCLUDE" 101; then exit 1; fi
guest_id_matches "$EXCLUDE" 102

ONLY="does-not-exist"
EXCLUDE="101"
apply_only_exclude_tags ONLY EXCLUDE
[[ "$ONLY" == __uu_no_matching_only__ && "$EXCLUDE" == "101" ]]

cat > "$WORK_DIR/update.conf" <<'CONFIG'
ONLY_UPDATE_CHECK="alpha"
EXCLUDE_UPDATE_CHECK="alpha"
ONLY=""
EXCLUDE=""
CONFIG
export EXTERNAL_SELECTION_CONFIG_FILE="$WORK_DIR/update.conf"
# shellcheck disable=SC1091
source "$ROOT_DIR/external-selection.sh"
if external_selection_allows check alpha; then exit 1; fi
if external_selection_allows check beta; then exit 1; fi

sed -i 's/ONLY_UPDATE_CHECK="alpha"/ONLY_UPDATE_CHECK=""/; s/EXCLUDE_UPDATE_CHECK="alpha"/EXCLUDE_UPDATE_CHECK="beta"/' "$WORK_DIR/update.conf"
if external_selection_allows check alpha; then :; else exit 1; fi
if external_selection_allows check beta; then exit 1; fi

echo 'filter semantics tests: PASS'
