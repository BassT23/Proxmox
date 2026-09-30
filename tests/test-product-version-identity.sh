#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT_DIR/product-metadata.sh"

sha=0123456789abcdef0123456789abcdef01234567
[[ "$(UU_FORMAT_BUILD_IDENTITY 5.1.3 master '' "$sha")" == "5.1.3" ]]
[[ "$(UU_FORMAT_BUILD_IDENTITY 5.1.3 beta 7 "$sha")" == "5.1.3 Beta 7 · 0123456" ]]
[[ "$(UU_FORMAT_BUILD_IDENTITY 5.1.3 develop '' "$sha")" == "5.1.3 develop · 0123456" ]]
[[ "$(UU_FORMAT_BUILD_IDENTITY 5.1.3 beta '' unknown)" == "5.1.3 beta" ]]

if grep -Fq 'Version :   2.1' "$ROOT_DIR/install.sh"; then
  echo 'installer still presents its internal version as the product version' >&2
  exit 1
fi
grep -Fq 'INSTALLER_VERSION="2.1"' "$ROOT_DIR/install.sh"
grep -Fq 'PRODUCT_VERSION="5.1.3"' "$ROOT_DIR/product-metadata.sh"
grep -Fq 'BETA_VERSION="7"' "$ROOT_DIR/product-metadata.sh"
grep -Fq 'schema_version=2' "$ROOT_DIR/install.sh"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
eval "$(sed -n '/^WRITE_BUILD_METADATA()/,/^}/p' "$ROOT_DIR/install.sh")"
BUILD_METADATA_FILE="$work_dir/build-metadata" PRODUCT_VERSION=5.1.3 \
  WRITE_BUILD_METADATA beta "$sha" '' 5.1.3 7
grep -Fqx 'schema_version=2' "$work_dir/build-metadata"
grep -Fqx 'version="5.1.3"' "$work_dir/build-metadata"
grep -Fqx 'branch="beta"' "$work_dir/build-metadata"
grep -Fqx 'beta="7"' "$work_dir/build-metadata"
grep -Fqx "commit=\"$sha\"" "$work_dir/build-metadata"

echo 'product version identity tests: PASS'
