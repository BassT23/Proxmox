#!/usr/bin/env python3
"""Config schema classification, migration and Web UI save-safety checks."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


def assignment_keys(content):
    return set(re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*=", content, re.MULTILINE))


dist_keys = assignment_keys((ROOT / "update.conf.dist").read_text(encoding="utf-8"))
classified = set(server.CONFIG_KEY_CATEGORIES)
assert dist_keys <= classified, sorted(dist_keys - classified)
assert server.CONFIG_KEYS == {
    key for key, category in server.CONFIG_KEY_CATEGORIES.items()
    if category in {"visible", "advanced"}
}

legacy = (ROOT / "tests/fixtures/update.conf.v4.2").read_text(encoding="utf-8")
legacy_known = assignment_keys(legacy) - {"CUSTOM_USER_KEY"}
assert legacy_known <= classified, sorted(legacy_known - classified)
assert server.CONFIG_KEY_CATEGORIES["INCLUDE_KERNEL"] == "deprecated"

original = (
    'VERSION="2.1"\n'
    'VERSION_CHECK="true"\n'
    'CUSTOM_USER_KEY="keep this value"\n'
    'INCLUDE_KERNEL="false"\n'
)
updated = server.update_config_text(original, {"VERSION_CHECK": "false"})
assert 'VERSION_CHECK="false"' in updated
assert 'CUSTOM_USER_KEY="keep this value"' in updated
assert 'INCLUDE_KERNEL="false"' in updated

work = ROOT / "tests/.config-coverage-work"
if work.exists():
    raise AssertionError(f"unexpected test directory exists: {work}")
work.mkdir()
try:
    user = work / "update.conf"
    user.write_text(legacy, encoding="utf-8")
    subprocess.run(
        ["bash", str(ROOT / "config-merge.sh"), str(user), str(ROOT / "update.conf.dist"), "beta"],
        check=True,
        text=True,
        capture_output=True,
    )
    merged = user.read_text(encoding="utf-8")
    assert 'VERSION="2.1"' in merged
    assert 'USED_BRANCH="beta"' in merged
    assert 'SSH_PORT="2222"' in merged
    assert 'INCLUDE_KERNEL="false"' in merged
    assert 'CUSTOM_USER_KEY="preserve-me"' in merged
    assert merged.count("VERSION=") == 1
    assert merged.count("SSH_PORT=") == 1
    assert 'EXE_FOR_INTERNET_CHECK="ping"' in merged
    print("config coverage, migration and save-safety tests: PASS")
finally:
    for path in sorted(work.glob("*"), reverse=True):
        path.unlink()
    work.rmdir()
