#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
python3 - "$root/update.sh" "$temporary/guard.sh" "$temporary/pin" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
needle="CHECK_EXTERNAL_RELEASE_PIN() {"
assert source.count(needle)==1
start=source.index(needle)
end=source.index("\n}\n",start)+3
function=source[start:end]
marker="/etc/ultimate-updater/.source-release-pin"
assert marker in function and "return 78" in function
branch=source.split("RUN_BRANCH_UPDATE () {",1)[1].split("SHOW_UPDATE_NOTICE () {",1)[0]
assert branch.index("CHECK_EXTERNAL_RELEASE_PIN") < branch.index("DOWNLOAD_SHELL_FILE")
download=source.split("RUN_DOWNLOADED_INSTALLER() {",1)[1].split("SHOULD_CLEAR_UPDATE_HEADER() {",1)[0]
assert download.index("CHECK_EXTERNAL_RELEASE_PIN") < download.index("DOWNLOAD_SHELL_FILE")
assert 'if [[ "$command" != uninstall ]]' in download
Path(sys.argv[2]).write_text(function.replace(marker,sys.argv[3]))
PY
bash -n "$temporary/guard.sh"
bash -c 'source "$1"; CHECK_EXTERNAL_RELEASE_PIN' _ "$temporary/guard.sh"
: > "$temporary/pin"
set +e
bash -c 'source "$1"; CHECK_EXTERNAL_RELEASE_PIN' _ "$temporary/guard.sh" 2>"$temporary/denial"
status=$?
set -e
[[ "$status" == 78 ]]
grep -Fq 'external verified release procedure' "$temporary/denial"
rm -f "$temporary/pin"
ln -s /nonexistent "$temporary/pin"
set +e
bash -c 'source "$1"; CHECK_EXTERNAL_RELEASE_PIN' _ "$temporary/guard.sh" 2>"$temporary/dangling-denial"
status=$?
set -e
[[ "$status" == 78 ]]
echo 'external source pin guard: PASS'
