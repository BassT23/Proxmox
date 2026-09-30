#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

legacy_parse_version() {
  local file="$1" parsed
  parsed=$(awk -F'"' '/^VERSION=/ {print $2; exit}' "$file")
  [[ "$parsed" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  printf '%s\n' "$parsed"
}

current_version=$(legacy_parse_version "$ROOT_DIR/update.sh")
[[ "$current_version" == "5.1.3" ]]

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
for branch in master beta develop; do
  printf '#!/bin/bash\nVERSION="5.1.3"\n' > "$work_dir/$branch-update.sh"
  [[ "$(legacy_parse_version "$work_dir/$branch-update.sh")" == "5.1.3" ]]
done

metadata_version=$(awk -F'"' '/^PRODUCT_VERSION=/ {print $2; exit}' "$ROOT_DIR/product-metadata.sh")
metadata_beta=$(awk -F'"' '/^BETA_VERSION=/ {print $2; exit}' "$ROOT_DIR/product-metadata.sh")
[[ "$metadata_version" == "$current_version" ]]
[[ "$metadata_beta" == 7 ]]

# Keep the exact pre-0575441 parser contract visible in the test itself.
git show b70e219:tag-filter.sh | grep -Fq '/^VERSION=/ {print $2; exit}'

if grep -Fq 'Version :   2.1' "$ROOT_DIR/install.sh"; then
  echo 'internal installer version is still user-visible' >&2
  exit 1
fi

echo 'legacy version bootstrap compatibility tests: PASS'
