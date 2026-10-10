#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(mktemp -d)"
trap 'rm -rf -- "$workspace"' EXIT
native="$workspace/native"
mkdir -m 0700 "$native"
printf '#!/bin/bash\n' > "$native/update.sh"
printf 'PRODUCT_VERSION="5.1.3"\n' > "$native/product-metadata.sh"
printf '#!/bin/bash\n' > "$native/config-merge.sh"

# The native product owns only an installation source-directory seam.
# Reach separately verifies published immutable tags, archives, and digests.
eval "$(sed -n '/^PREPARE_SOURCE_FILES()/,/^}/p' "$root/install.sh")"
[[ "$(type -t PREPARE_SOURCE_FILES)" == function ]]
source_text="$(sed -n '/^PREPARE_SOURCE_FILES()/,/^}/p' "$root/install.sh")"
if grep -Eq 'sha256sum|tar -tzf|curl|wget|gh release' <<< "$source_text"; then
  printf 'Native staged-source adapter must not implement generic archive verification\n' >&2
  exit 1
fi

export UU_STAGED_SOURCE_DIR="$native"
export UU_STAGED_SOURCE_COMMIT="e2ce17043dd49e789e7b872966cbedf0d2c90555"
export UU_STAGED_SOURCE_TAG="v5.1.3-x1pher.2"
TEMP_FOLDER="$workspace/temp"
mkdir "$TEMP_FOLDER"
BRANCH=master
ARCHIVE_COMMIT='' ARCHIVE_TAG='' TEMP_FILES=''
DOWNLOAD_ARCHIVE() { printf 'Unexpected upstream download\n' >&2; return 92; }
READ_PAYLOAD_METADATA() { [[ -f "$TEMP_FILES/update.sh" ]]; }
PREPARE_SOURCE_FILES
[[ "$TEMP_FILES" == "$native" ]]
[[ "$ARCHIVE_COMMIT" == "$UU_STAGED_SOURCE_COMMIT" ]]
[[ "$ARCHIVE_TAG" == "$UU_STAGED_SOURCE_TAG" ]]
[[ ! -e "$TEMP_FOLDER/ultimate-updater.tar.gz" ]]

fail_expected() {
  if PREPARE_SOURCE_FILES 2>"$workspace/error"; then
    printf 'Unsafe staged input was accepted\n' >&2; exit 1
  fi
  grep -Fq 'Staged source' "$workspace/error"
}
UU_STAGED_SOURCE_TAG=''
fail_expected
UU_STAGED_SOURCE_TAG="v5.1.3-x1pher.2"
UU_STAGED_SOURCE_COMMIT="invalid"
fail_expected
UU_STAGED_SOURCE_COMMIT="e2ce17043dd49e789e7b872966cbedf0d2c90555"
BRANCH=develop
fail_expected
BRANCH=master
TEMP_FOLDER="$native"
fail_expected
TEMP_FOLDER="$workspace/temp"
chmod 0770 "$native"
fail_expected
chmod 2700 "$native"
PREPARE_SOURCE_FILES
chmod 0700 "$native"
mv "$native" "$workspace/actual"
ln -s "$workspace/actual" "$native"
fail_expected
rm "$native"
mv "$workspace/actual" "$native"
mv "$native/update.sh" "$native/real-update.sh"
ln -s "$native/real-update.sh" "$native/update.sh"
fail_expected
rm "$native/update.sh"
mv "$native/real-update.sh" "$native/update.sh"
PREPARE_SOURCE_FILES

# Default online installer path remains unchanged when no source is supplied.
unset UU_STAGED_SOURCE_DIR UU_STAGED_SOURCE_COMMIT UU_STAGED_SOURCE_TAG
payload="$workspace/input/source-v1"
mkdir -p "$payload"
printf '#!/bin/bash\n' > "$payload/update.sh"
DOWNLOAD_ARCHIVE() {
  tar -czf "$TEMP_FOLDER/ultimate-updater.tar.gz" -C "$workspace/input" source-v1
  ARCHIVE_COMMIT=''
  ARCHIVE_TAG=''
}
SET_TEMP_FILES() {
  [[ -f "$TEMP_FOLDER/source-v1/update.sh" ]]
  TEMP_FILES="$TEMP_FOLDER/source-v1"
}
PREPARE_SOURCE_FILES
[[ "$TEMP_FILES" == "$TEMP_FOLDER/source-v1" ]]
[[ ! -e "$TEMP_FOLDER/ultimate-updater.tar.gz" ]]

# Both native install and update must use this source selector.
python3 - "$root/install.sh" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
for name in ("INSTALL","UPDATE"):
    hit=re.search(rf"(?m)^{name} \(\) \{{(?P<body>.*?)(?=^\}}$)",text,re.DOTALL|re.MULTILINE)
    assert hit, name
    body=hit.group("body")
    assert "PREPARE_SOURCE_FILES" in body, name
    if name == "UPDATE":
        assert 'if [[ -z "${UU_STAGED_SOURCE_DIR:-}" ]]; then' in body
        assert body.index('if [[ -z "${UU_STAGED_SOURCE_DIR:-}" ]]; then') < body.index('rm -rf "$TEMP_FOLDER"')
print("native source hook installed in install and update")
PY
printf 'native staged source seam tests: PASS\n'
