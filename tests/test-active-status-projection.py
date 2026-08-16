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

canonical = module.active_inventory_projection(payload, [
    {"id": "mediacenter", "transport": "ssh"},
    {"id": "legacy-971", "transport": "ssh"},
])
canonical_ids = [item["id"] for item in canonical["targets"]]
assert canonical_ids == ["mediacenter", "host:Proxmox-Test-1", "912", "legacy-971"], canonical_ids
assert canonical["targets"][-1]["check_status"] == "unknown"

resources = [
    {"type": "node", "node": "Proxmox-Test-1", "status": "online"},
    {"type": "node", "node": "Proxmox-Test-3", "status": "offline"},
    {"type": "lxc", "vmid": 917, "node": "Proxmox-Test-1", "name": "cent", "template": 0},
    {"type": "lxc", "vmid": 926, "node": "Proxmox-Test-1", "name": "template", "template": 1},
    {"type": "lxc", "vmid": 930, "node": "Proxmox-Test-3", "name": "offline-guest", "template": 0},
]
full = module.canonical_inventory(payload, [{"id": "mediacenter", "transport": "ssh"}], resources)
full_ids = [item["id"] for item in full["targets"]]
assert full_ids == ["host:Proxmox-Test-1", "host:Proxmox-Test-3", "917", "930", "mediacenter"], full_ids
assert next(item for item in full["targets"] if item["id"] == "930")["check_status"] == "offline"
assert all(item["id"] != "ct927" for item in full["targets"])

print("active status projection tests: PASS")
