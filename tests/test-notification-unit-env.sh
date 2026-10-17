#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root/job-runner.sh" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for start, stop in (
    ("start_job() {", "start_global_job() {"),
    ("start_global_job() {", "start_check_job() {"),
    ("start_check_job() {", "start_selfupdate_job() {"),
):
    assert start in text and stop in text, (start, stop)
    section = text.split(start, 1)[1].split(stop, 1)[0]
    assert "append_notification_envfile systemd_env || return" in section, (
        "Protected notification settings gate absent from " + start
    )
assert "--setenv=UU_APPRISE_URLS_FILE=" not in text
assert "--setenv=UU_APPRISE_PROVIDER_TOKEN=" not in text
assert "EnvironmentFile=-/etc/ultimate-updater/notification-integration.conf" not in text
PY

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
awk '/^append_notification_envfile\(\) \{/{printing=1} printing {print; if ($0 ~ /^}$/) exit}' \
    "$root/job-runner.sh" > "$work/guard.sh"
test -s "$work/guard.sh"
# shellcheck disable=SC1090
source "$work/guard.sh"

config="$work/notification-integration.conf"
args=(--setenv=UU_TEST=synthetic)
append_notification_envfile args "$config"
test "${#args[@]}" -eq 1

printf '%s\n' 'UU_APPRISE_PYTHON=/opt/example/venv/bin/python3' > "$config"
chmod 0600 "$config"
append_notification_envfile args "$config"
test "${#args[@]}" -eq 2
test "${args[1]}" = "--property=EnvironmentFile=$config"

for mode in 0640 0644; do
    chmod "$mode" "$config"
    args=(--setenv=UU_TEST=synthetic)
    if append_notification_envfile args "$config"; then
        echo "Unsafe EnvironmentFile accepted" >&2
        exit 1
    fi
    test "${#args[@]}" -eq 1
done

chmod 0600 "$config"
mv "$config" "$work/real-config"
ln -s "$work/real-config" "$config"
args=(--setenv=UU_TEST=synthetic)
if append_notification_envfile args "$config"; then
    echo "Symlinked EnvironmentFile accepted" >&2
    exit 1
fi
test "${#args[@]}" -eq 1
# A writable containing directory allows an attacker to replace an accepted file.
mkdir "$work/unsafe-directory"
chmod 0777 "$work/unsafe-directory"
cp "$work/real-config" "$work/unsafe-directory/config"
chmod 0600 "$work/unsafe-directory/config"
args=(--setenv=UU_TEST=synthetic)
if append_notification_envfile args "$work/unsafe-directory/config"; then
    echo "Writable EnvironmentFile parent accepted" >&2
    exit 1
fi
test "${#args[@]}" -eq 1
echo 'native notification unit environment ownership and mode checks: PASS'
