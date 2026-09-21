#!/usr/bin/env python3
"""Regression tests for Proxmox-native Web UI authentication."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_web", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


auth = server.ProxmoxAuth()
auth._request = lambda path, fields=None: (
    [{"realm": "pam", "comment": "Linux PAM standard authentication", "type": "pam"},
     {"realm": "pve", "comment": "Proxmox VE authentication server", "type": "pve"}]
    if path == "/access/domains" else
    {"ticket": "PVE:discarded-test-ticket", "username": "admin@pam"}
    if path == "/access/ticket" else
    [{"roleid": "Administrator", "privs": "Sys.Audit,VM.Audit"}]
)
auth._pvesh_json = lambda args: (
    {"/": {"Sys.Audit": 1, "VM.Audit": 1}}
    if any(item == "/access/permissions" for item in args) else
    [{"roleid": "Administrator", "privs": "Sys.Audit,VM.Audit"}]
)

realms = auth.realms()
assert [item["realm"] for item in realms["realms"]] == ["pam", "pve"]
assert realms["default_realm"] == "pam"
assert auth.authenticate("admin", "secret", "pam") == {"ok": True, "user": "admin@pam"}

auth._request = lambda path, fields=None: {"need_tfa": 1} if path == "/access/ticket" else realms["realms"]
assert auth.authenticate("admin", "secret", "pam")["code"] == "TFA_REQUIRED"

auth._request = lambda path, fields=None: {"ticket": "discarded", "username": "admin@pam"} if path == "/access/ticket" else realms["realms"]
auth._pvesh_json = lambda args: {"/": {"Sys.Audit": 1}} if any(item == "/access/permissions" for item in args) else [{"roleid": "Administrator", "privs": "Sys.Audit,VM.Audit"}]
assert auth.authenticate("admin", "secret", "pam")["code"] == "LOGIN_UNAUTHORIZED"

auth._request = lambda path, fields=None: (_ for _ in ()).throw(server.ProxmoxAuthError())
assert auth.authenticate("admin", "secret", "pam")["code"] == "LOGIN_FAILED"

auth._request = lambda path, fields=None: realms["realms"]
assert auth.authenticate("admin", "secret", "unknown")["code"] == "LOGIN_FAILED"

print("web Proxmox auth tests: PASS")
