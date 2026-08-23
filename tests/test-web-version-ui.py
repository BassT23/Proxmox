#!/usr/bin/env python3
"""Regression coverage for the Web UI updater version/self-update boundary."""

import importlib.util
import tempfile
from pathlib import Path
from types import SimpleNamespace

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
assert "/api/public-version" in source
assert 'id="login-version"' in source
assert "loginVersionText" in source
assert "version_refresh_running" in source
assert "Schema ${text(data.schema_version)}" not in module.PAGE
assert "schema 1" not in module.PAGE.lower()
assert 'id="generated"' not in module.PAGE
assert 'Generated ${date(data.generated_at)}' not in module.PAGE
assert 'login-version-footer' in module.PAGE
assert '<p class="login-account-hint">Sign in with the local Proxmox root account.</p>' in module.PAGE
assert 'id="login-message"' in module.PAGE
login_markup = module.PAGE.split('<section id="login-screen"', 1)[1].split('</section>', 1)[0]
assert login_markup.count('class="login-branding"') == 1
assert '<h2>Ultimate Updater</h2>' not in login_markup
assert 'Sign in to access system status and actions.' not in login_markup
assert 'Sign in with the local Proxmox root account.' in login_markup
assert 'name="username"' in login_markup
assert 'name="password"' in login_markup
assert '>Sign in</button>' in login_markup
assert login_markup.index('login-branding') < login_markup.index('login-account-hint') < login_markup.index('name="username"')

with tempfile.TemporaryDirectory() as directory:
    root_dir = Path(directory)
    update = root_dir / "update.sh"
    update.write_text('#!/bin/bash\nVERSION="5.1"\n', encoding="utf-8")
    (root_dir / "update.conf").write_text('USED_BRANCH="beta"\n', encoding="utf-8")
    (root_dir / "build-metadata").write_text(
        'schema_version=1\nbranch="beta"\ncommit="0123456789abcdef0123456789abcdef01234567"\ntag="v5.1-beta"\n',
        encoding="utf-8",
    )
    handler = object.__new__(module.StatusHandler)
    handler.server = SimpleNamespace(config_file=root_dir / "update.conf", update_script=update)
    local = handler.local_version()
    assert local["state"] == "local"
    assert (local["installed"], local["branch"], local["commit"], local["tag"]) == (
        "5.1", "beta", "0123456789abcdef0123456789abcdef01234567", "v5.1-beta"
    )
    handler.start_version_refresh = lambda: setattr(handler.server, "refresh_started", True)
    handler.server.version_last_data = None
    public = handler.public_version()
    assert public["installed"] == "5.1"
    assert public["branch"] == "beta"
    assert public["update_state"] == "checking"
    assert handler.server.refresh_started is True
    handler.server.version_last_data = {
        "state": "unavailable", "update_available": False,
        "installed": None, "branch": None, "commit": "unknown",
    }
    offline = handler.public_version()
    assert offline["installed"] == "5.1"
    assert offline["branch"] == "beta"
    assert offline["update_state"] == "unavailable"
print("web updater version/self-update tests: PASS")
