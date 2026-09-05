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
    {"type": "qemu", "vmid": 100, "node": "Proxmox-Test-1", "name": "pfsense", "template": 0},
]
payload["targets"].append({
    "id": "100", "type": "vm", "transport": "ssh", "os": "pfSense",
    "updater": "pkg", "check_status": "updates_available",
})
full = module.canonical_inventory(payload, [{"id": "mediacenter", "transport": "ssh"}], resources)
full_ids = [item["id"] for item in full["targets"]]
assert full_ids == ["host:Proxmox-Test-1", "host:Proxmox-Test-3", "917", "930", "100", "mediacenter"], full_ids
assert next(item for item in full["targets"] if item["id"] == "930")["check_status"] == "offline"
pfSense = next(item for item in full["targets"] if item["id"] == "100")
assert pfSense["transport"] == "ssh"
assert pfSense["updater"] == "pkg"
assert all(item["id"] != "ct927" for item in full["targets"])

stale_online = {
    "schema_version": 1,
    "targets": [{
        "id": "host:Proxmox-Test-2", "type": "host", "reachable": False,
        "check_status": "offline", "error": None,
    }],
}
online = module.canonical_inventory(
    stale_online, [], [{"type": "node", "node": "Proxmox-Test-2", "status": "online"}],
)["targets"][0]
assert online["reachable"] is True
assert online["check_status"] == "unknown"

fresh_online = {
    "schema_version": 1,
    "targets": [{
        "id": "host:Proxmox-Test-2", "type": "host", "reachable": True,
        "check_status": "ok", "error": None,
    }],
}
healthy = module.canonical_inventory(
    fresh_online, [], [{"type": "node", "node": "Proxmox-Test-2", "status": "online"}],
)["targets"][0]
assert healthy["reachable"] is True
assert healthy["check_status"] == "ok"

check_error = {
    "schema_version": 1,
    "targets": [{
        "id": "host:Proxmox-Test-2", "type": "host", "reachable": False,
        "check_status": "offline", "error": {"code": "REMOTE_STATUS_IMPORT_FAILED", "message": "fixture"},
    }],
}
error = module.canonical_inventory(
    check_error, [], [{"type": "node", "node": "Proxmox-Test-2", "status": "online"}],
)["targets"][0]
assert error["reachable"] is True
assert error["check_status"] == "error"

offline = module.canonical_inventory(
    stale_online, [], [{"type": "node", "node": "Proxmox-Test-2", "status": "offline"}],
)["targets"][0]
assert offline["reachable"] is False
assert offline["check_status"] == "offline"

print("active status projection tests: PASS")
