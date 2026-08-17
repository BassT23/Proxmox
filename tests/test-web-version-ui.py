#!/usr/bin/env python3
"""Regression coverage for the Web UI updater version/self-update boundary."""

import importlib.util
from pathlib import Path

root = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sample = """Version overview (beta)
Component    Local     Server
Updater      5.1       5.2
Extras       3.1       3.1
Config       2.1       2.1
Welcome      3.0       3.0
Check        2.1       2.1
"""
parsed = module.parse_updater_version_output(sample)
assert parsed["state"] == "ok"
assert parsed["branch"] == "beta"
assert parsed["installed"] == "5.1"
assert parsed["available"] == "5.2"
assert parsed["update_available"] is True
assert len(parsed["components"]) == 5

unavailable = module.parse_updater_version_output("Version overview (beta)\nUpdater 5.1 unavailable")
assert unavailable["state"] == "unavailable"
assert unavailable["update_available"] is False

source = (root / "web-ui/server.py").read_text(encoding="utf-8")
runner = (root / "job-runner.sh").read_text(encoding="utf-8")
for marker in (
    "/api/updater-version", "version_cache", "Update now", "updater-version-indicator",
    "start-selfupdate", "UU_NONINTERACTIVE",
):
    assert marker in source or marker in runner, marker
assert "run-selfupdate" in runner
assert "curl" not in source
assert "wget" not in source
print("web updater version/self-update tests: PASS")
