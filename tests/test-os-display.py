#!/usr/bin/env python3
"""Compact OS overview labels while retaining raw status data."""

import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

cases = {
    ("Operating System: Debian GNU/Linux 12 (bookworm)", None): "Debian 12",
    ("Debian GNU/Linux 13 (trixie)", None): "Debian 13",
    ("Ubuntu 24.04.3 LTS", None): "Ubuntu 24.04",
    ("debian", "12"): "Debian 12",
    ("ubuntu", "24.04"): "Ubuntu 24.04",
    ("FreeBSD 15.0-CURRENT", None): "FreeBSD 15",
    ("FreeBSD 14.2-RELEASE-p3", None): "FreeBSD 14.2",
    ("pfSense", "FreeBSD 15.0-CURRENT"): "FreeBSD 15",
    ("Unknown", None): "Unknown",
}
for (raw, version), expected in cases.items():
    assert server.normalize_os_display(raw, version) == expected, (raw, version)

payload = {"targets": [{"id": "1", "os": "Debian GNU/Linux 12 (bookworm)"}]}
projected = server.annotate_health_state(payload)
assert projected["targets"][0]["os_display"] == "Debian 12"
assert "os_display" not in payload["targets"][0]

print("OS display normalization tests: PASS")
