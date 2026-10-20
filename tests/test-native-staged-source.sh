#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT_DIR/install.sh"
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

source="$WORK_DIR/source"
TEMP_FOLDER="$WORK_DIR/native-temp"
mkdir -m 0700 "$TEMP_FOLDER"

eval "$(sed -n \
  -e '/^STAGED_SOURCE_REQUESTED()/,/^}/p' \
  -e '/^READ_PAYLOAD_METADATA()/,/^}/p' \
  -e '/^PREPARE_STAGED_SOURCE_INPUT()/,/^}/p' \
  "$INSTALLER")"

make_source() {
  local root="$1" required
  rm -rf -- "$root"
  mkdir -p "$root"
  chmod 0700 "$root"
  while IFS= read -r required; do
    mkdir -p -- "$root/$(dirname -- "$required")"
    case "$required" in
      product-metadata.sh)
        printf 'PRODUCT_VERSION="5.2"\nBETA_VERSION="1"\n' > "$root/$required"
        ;;
      update.conf)
        printf 'USED_BRANCH="master"\n' > "$root/$required"
        ;;
      README.md)
        printf '# staged fixture\n' > "$root/$required"
        ;;
      *)
        printf '#!/usr/bin/env bash\n' > "$root/$required"
        ;;
    esac
  done <<'EOF'
update.sh
product-metadata.sh
README.md
VMs/example
welcome-screen.sh
update-extras.sh
check-updates.sh
qga-guest-exec.sh
tag-filter.sh
target-selection.sh
target-inventory.sh
targets.conf
status-model.sh
windows-update.sh
target-runtime.sh
apt-count.py
apt-count.sh
rpm-count.py
package-count.sh
internal-ssh.sh
config-merge.sh
web-ui-port.sh
ultimate-updater
job-runner.sh
web-ui/server.py
ultimate-updater-web.service
update.conf
EOF
  mkdir -p -- "$root/exit" "$root/scripts.d/000"
  printf '#!/usr/bin/env bash\n' > "$root/exit/example.sh"
  printf '#!/usr/bin/env bash\n' > "$root/scripts.d/000/example.sh"
}

set_valid_identity() {
  BRANCH=master
  UU_STAGED_SOURCE_DIR="$source"
  UU_STAGED_SOURCE_COMMIT="0123456789abcdef0123456789abcdef01234567"
  UU_STAGED_SOURCE_TAG="v5.2.0"
  export UU_STAGED_SOURCE_DIR UU_STAGED_SOURCE_COMMIT UU_STAGED_SOURCE_TAG
}

expect_reject() {
  if PREPARE_STAGED_SOURCE_INPUT >/dev/null 2>&1; then
    echo 'unsafe staged source input was accepted' >&2
    exit 1
  fi
  [[ "$STAGED_SOURCE_ACTIVE" == false ]]
}

make_source "$source"
set_valid_identity
STAGED_SOURCE_ACTIVE=false
TEMP_FILES=''
PREPARE_STAGED_SOURCE_INPUT
[[ "$STAGED_SOURCE_ACTIVE" == true ]]
[[ "$TEMP_FILES" == "$source" ]]
[[ "$ARCHIVE_COMMIT" == "0123456789abcdef0123456789abcdef01234567" ]]
[[ "$ARCHIVE_TAG" == "v5.2.0" ]]

chmod 2700 "$source"
STAGED_SOURCE_ACTIVE=false
PREPARE_STAGED_SOURCE_INPUT
[[ "$STAGED_SOURCE_ACTIVE" == true ]]
chmod 0700 "$source"

set_valid_identity
unset UU_STAGED_SOURCE_TAG
expect_reject
set_valid_identity
UU_STAGED_SOURCE_COMMIT=invalid
expect_reject
set_valid_identity
UU_STAGED_SOURCE_TAG=release-5.2
expect_reject
set_valid_identity
# The extracted production function reads BRANCH indirectly.
# shellcheck disable=SC2034
BRANCH=develop
expect_reject
set_valid_identity
rm -f "$source/target-runtime.sh"
expect_reject
set_valid_identity
make_source "$source"

set_valid_identity
rm -f "$source/update.sh"
printf '#!/usr/bin/env bash\n' > "$WORK_DIR/real-update.sh"
ln -s "$WORK_DIR/real-update.sh" "$source/update.sh"
expect_reject
rm -f "$source/update.sh"
make_source "$source"

set_valid_identity
chmod 0750 "$source"
expect_reject
chmod 0700 "$source"

set_valid_identity
inside="$TEMP_FOLDER/source"
make_source "$inside"
UU_STAGED_SOURCE_DIR="$inside"
export UU_STAGED_SOURCE_DIR
expect_reject
rm -rf -- "$inside"

set_valid_identity
actual="$WORK_DIR/actual-source"
mv "$source" "$actual"
ln -s "$actual" "$source"
expect_reject
rm "$source"
mv "$actual" "$source"

set_valid_identity
# The production function invokes the test double indirectly through stat.
# shellcheck disable=SC2329
stat() {
  if [[ "$*" == *"$source"* ]]; then
    printf '65534 700\n'
  else
    command stat "$@"
  fi
}
expect_reject
unset -f stat

unset UU_STAGED_SOURCE_DIR UU_STAGED_SOURCE_COMMIT UU_STAGED_SOURCE_TAG
STAGED_SOURCE_ACTIVE=false
TEMP_FILES=unchanged
PREPARE_STAGED_SOURCE_INPUT
[[ "$STAGED_SOURCE_ACTIVE" == false ]]
[[ "$TEMP_FILES" == unchanged ]]

python3 - "$INSTALLER" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for name in ("INSTALL", "UPDATE"):
    match = re.search(rf"(?m)^{name} \(\) \{{(?P<body>.*?)(?=^\}}$)", text, re.DOTALL)
    assert match, name
    body = match.group("body")
    assert "PREPARE_STAGED_SOURCE_INPUT || return $?" in body
    assert body.index("PREPARE_STAGED_SOURCE_INPUT") < body.index("DOWNLOAD_ARCHIVE")
assert "STAGED_SOURCE_ACTIVE" in text
print("native staged-source lifecycle hooks: PASS")
PY

printf 'native staged source validation tests: PASS\n'
