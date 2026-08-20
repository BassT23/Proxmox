#!/usr/bin/env python3
"""Regression coverage for the Web UI updater version/self-update boundary."""

import importlib.util
from pathlib import Path

root = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

sample = """Version overview (beta)
Installed commit: 0123456789abcdef0123456789abcdef01234567
Available commit: 89abcdef0123456789abcdef0123456789abcdef
Installed tag: —
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
assert parsed["commit"] == "0123456789abcdef0123456789abcdef01234567"
assert parsed["available_commit"] == "89abcdef0123456789abcdef0123456789abcdef"
assert parsed["tag"] is None
assert len(parsed["components"]) == 5

unavailable = module.parse_updater_version_output("Version overview (beta)\nUpdater 5.1 unavailable")
assert unavailable["state"] == "unavailable"
assert unavailable["update_available"] is False

same_version_new_commit = module.parse_updater_version_output("""Version overview (develop)
Installed commit: 0123456789abcdef0123456789abcdef01234567
Available commit: 89abcdef0123456789abcdef0123456789abcdef
Installed tag: —
Updater 5.1 5.1
""")
assert same_version_new_commit["update_available"] is True

source = (root / "web-ui/server.py").read_text(encoding="utf-8")
runner = (root / "job-runner.sh").read_text(encoding="utf-8")
installer = (root / "install.sh").read_text(encoding="utf-8")
update_script = (root / "update.sh").read_text(encoding="utf-8")
for marker in (
    "/api/updater-version", "version_cache", "Update now", "updater-version-indicator",
    "start-selfupdate", "UU_NONINTERACTIVE",
):
    assert marker in source or marker in runner, marker
assert "run-selfupdate" in runner
assert "WRITE_BUILD_METADATA" in installer
assert "ARCHIVE_COMMIT" in installer
assert "BUILD_METADATA_FILE" in update_script
assert "FETCH_REMOTE_COMMIT" in update_script
assert "curl" not in source
assert "wget" not in source
assert "<span id=\"updater-version-label\">version unavailable</span></button></footer>" in source
assert "/etc/ultimate-updater/status.json" not in source.split("<footer>", 1)[1].split("</footer>", 1)[0]
assert "<span>Branch</span>" in source
assert "<span>Commit</span>" in source
assert "<span>Tag</span>" in source
assert "<th>Installed</th><th>Available</th>" in source
assert "<td>Local" not in source
assert "<td>Server" not in source
assert "versionFooterDisplay" in source
assert "shortCommit" in source
assert "data.update_available===true" in source
assert "updateButton.textContent=data.state==='ok'&&data.update_available===true?'Update now':'Up to date'" in source
assert "scheduleUpdaterVersionCheck" in source
assert "2500" in source and "7000" in source
assert "self.server.version_cache = {\"at\": now, \"data\": data} if data.get(\"state\") == \"ok\" else None" in source
print("web updater version/self-update tests: PASS")
