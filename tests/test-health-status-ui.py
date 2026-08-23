#!/usr/bin/env python3
"""Regression tests for health badges on projected inventory records."""

import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def target(**overrides):
    value = {
        "type": "vm", "reachable": True, "last_check": "2026-08-23T10:00:00Z",
        "check_status": "ok", "updates": {"available": 0},
        "reboot_required": False, "updater": "pkg",
    }
    value.update(overrides)
    return value


assert server.derive_health_state(target()) == "known"
assert server.derive_health_state(target(updates={"available": 5}, check_status="updates_available")) == "known"
assert server.derive_health_state(target(updates={"available": 0}, security_split_supported=False)) == "known"
assert server.derive_health_state(target(updater="apt")) == "unknown"
assert server.derive_health_state({"type": "vm", "reachable": None, "check_status": "unknown"}) == "unknown"
assert server.derive_health_state(target(last_check=None)) == "unknown"
assert server.derive_health_state(target(updates={"available": None})) == "unknown"
assert server.derive_health_state(target(reachable=False)) == "attention"
assert server.derive_health_state(target(check_status="not_checked", reachable=False)) == "unknown"
assert server.derive_health_state(target(check_status="unsupported", updates={"available": None})) == "known"

partial = {
    "schema_version": 1,
    "targets": [target(id="1"), {"id": "2", "type": "vm", "reachable": None,
                                "check_status": "unknown"}],
}
projected = server.annotate_health_state(partial)
assert projected["targets"][0]["health_state"] == "known"
assert projected["targets"][1]["health_state"] == "unknown"
assert "health_state" not in partial["targets"][0]

resources = [{"type": "node", "node": "node1", "status": "online"}]
inventory_only = server.canonical_inventory({"schema_version": 1, "targets": []}, [], resources)
node = inventory_only["targets"][0]
assert node["check_status"] == "unknown"
assert node["health_state"] == "unknown"

source = (root / "web-ui" / "server.py").read_text(encoding="utf-8")
assert "def derive_health_state(target):" in source
assert 'item["health_state"] = derive_health_state(item)' in source
assert "const healthState=t=>" in source
assert "health==='unknown'" in source
assert "class=\"pill ${tone}${securityClass}\"" in source
assert ".pill.neutral" in source

print("health status UI regression tests: PASS")
