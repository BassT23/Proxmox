#!/usr/bin/env python3
"""Regression coverage for the optional dpkg-repair WebUI setting."""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


legacy = 'VERSION="2.1"\nWITH_HOST="true"\n'
values = server.config_value_map(legacy)
assert values["APT_AUTO_REPAIR_DPKG"] is False
assert "APT_AUTO_REPAIR_DPKG" in server.CONFIG_KEYS
assert server.validate_config_values({"APT_AUTO_REPAIR_DPKG": True}) == {
    "APT_AUTO_REPAIR_DPKG": "true"
}
updated = server.update_config_text(legacy, {"APT_AUTO_REPAIR_DPKG": "true"})
assert 'APT_AUTO_REPAIR_DPKG="true"' in updated
assert server.config_value_map(updated)["APT_AUTO_REPAIR_DPKG"] is True

page = server.PAGE
assert "APT_AUTO_REPAIR_DPKG" in page
assert "Repair interrupted dpkg before APT updates" in page
assert "dpkg --configure -a may run package configuration and maintainer scripts" in page
assert "the Proxmox host may have no snapshot protection" in page
assert "Enable only when explicitly desired" in page

print("dpkg repair WebUI configuration tests: PASS")
