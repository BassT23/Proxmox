#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

payload = {
    "schema_version": 1,
    "generated_at": "now",
    "targets": [
        {"id": "mediacenter", "type": "external", "transport": "ssh"},
        {"id": "ct927", "type": "external", "transport": "ssh"},
        {"id": "host:Proxmox-Test-1", "type": "host", "transport": "local"},
        {"id": "912", "type": "lxc", "transport": "pct"},
    ],
}
projected = module.project_active_status(payload, {"mediacenter"})
ids = [item["id"] for item in projected["targets"]]
assert ids == ["mediacenter", "host:Proxmox-Test-1", "912"], ids
assert payload["targets"][1]["id"] == "ct927"
assert module.project_active_status(payload, set())["targets"][0]["id"] == "host:Proxmox-Test-1"

print("active status projection tests: PASS")

