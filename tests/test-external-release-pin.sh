#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

PIN="$WORK_DIR/.source-release-pin"
CALLS="$WORK_DIR/download-calls"
INSTALLER="$WORK_DIR/installer.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$INSTALLER"
chmod 700 "$INSTALLER"

python3 - "$ROOT_DIR/update.sh" "$WORK_DIR/extracted.sh" "$PIN" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output = Path(sys.argv[2])
pin = sys.argv[3]

def function(name):
    match = re.search(
        r"(?m)^" + re.escape(name) + r"\s*\(\)\s*\{(?P<body>.*?)(?=^\}\n)",
        source,
        re.DOTALL,
    )
    assert match, name
    return match.group(0) + "}"

guard = function("CHECK_EXTERNAL_RELEASE_PIN").replace(
    '"/etc/ultimate-updater/.source-release-pin"', repr(pin)
)
runner = function("RUN_DOWNLOADED_INSTALLER")
branch = function("RUN_BRANCH_UPDATE")
for name, body in (("runner", runner), ("branch", branch)):
    assert body.index("CHECK_EXTERNAL_RELEASE_PIN") < body.index("DOWNLOAD_SHELL_FILE"), name

update_function = function("UPDATE")
update_body = update_function.split("{", 1)[1]
assert update_body.index("CHECK_EXTERNAL_RELEASE_PIN") < update_body.index("FETCH_REMOTE_VERSION")
output.write_text(f"{guard}\n{runner}\n{branch}\n{update_function}\n", encoding="utf-8")
PY
bash -n "$WORK_DIR/extracted.sh"

DOWNLOAD_SHELL_FILE() {
  printf 'called\n' >> "$CALLS"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$INSTALLER"
  chmod 700 "$INSTALLER"
  printf '%s\n' "$INSTALLER"
}
export CALLS INSTALLER

assert_denied_before_download() {
  local label=$1
  shift
  : > "$CALLS"
  set +e
  "$@" >/dev/null 2>"$WORK_DIR/$label.err"
  local rc=$?
  set -e
  [[ "$rc" -eq 78 ]] || { echo "$label was not denied with 78" >&2; exit 1; }
  [[ ! -s "$CALLS" ]] || { echo "$label attempted a download" >&2; exit 1; }
  grep -Fq 'Externally managed Updater source is pinned' "$WORK_DIR/$label.err"
}

# shellcheck disable=SC1091 # the fixture is generated dynamically above.
source "$WORK_DIR/extracted.sh"

: > "$PIN"
assert_denied_before_download update_metadata UPDATE
assert_denied_before_download update_download RUN_DOWNLOADED_INSTALLER https://example.invalid/install.sh update
assert_denied_before_download install_download RUN_DOWNLOADED_INSTALLER https://example.invalid/install.sh install
assert_denied_before_download branch_download RUN_BRANCH_UPDATE master

rm -f "$PIN"
ln -s "$WORK_DIR/missing-release" "$PIN"
assert_denied_before_download dangling_update RUN_DOWNLOADED_INSTALLER https://example.invalid/install.sh update
assert_denied_before_download dangling_branch RUN_BRANCH_UPDATE beta

rm -f "$PIN"
: > "$CALLS"
RUN_DOWNLOADED_INSTALLER https://example.invalid/install.sh update >/dev/null
[[ -s "$CALLS" ]]

: > "$CALLS"
RUN_BRANCH_UPDATE master >/dev/null
[[ -s "$CALLS" ]]

: > "$PIN"
: > "$CALLS"
RUN_DOWNLOADED_INSTALLER https://example.invalid/install.sh uninstall >/dev/null
[[ -s "$CALLS" ]] || { echo 'uninstall was incorrectly blocked' >&2; exit 1; }

grep -Fq 'Issue #370' "$ROOT_DIR/docs/upgrading.md"
grep -Fq 'PR #371' "$ROOT_DIR/docs/upgrading.md"
grep -Fq 'X1/X1pheR' "$ROOT_DIR/docs/upgrading.md"
grep -Fq '.source-release-pin' "$ROOT_DIR/update.sh"

printf 'external source release pin guard: PASS\n'
