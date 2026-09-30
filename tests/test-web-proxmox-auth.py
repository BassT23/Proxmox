#!/usr/bin/env python3
"""Regression tests for Proxmox-native Web UI authentication."""

import importlib.util
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_web", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


REALMS = [
    {"realm": "pam", "comment": "Linux PAM standard authentication", "type": "pam"},
    {"realm": "pve", "comment": "Proxmox VE authentication server", "type": "pve"},
]
ROLE = [{"roleid": "Administrator", "privs": "Sys.Audit,VM.Audit"}]
FULL_PERMISSIONS = {"/": {"Sys.Audit": 1, "VM.Audit": 1}}


def make_auth(permission=FULL_PERMISSIONS):
    auth = server.ProxmoxAuth()
    calls = {"permissions": 0, "roles": 0}

    def request(path, fields=None):
        if path == "/access/domains":
            return REALMS
        if path == "/access/ticket":
            return {"ticket": "PVE:discarded-test-ticket", "username": "admin@pam"}
        raise AssertionError(f"unexpected API request: {path}")

    def pvesh(args):
        if "/access/permissions" in args:
            calls["permissions"] += 1
            return permission
        calls["roles"] += 1
        return ROLE

    auth._request = request
    auth._pvesh_json = pvesh
    return auth, calls


auth, calls = make_auth()
realms = auth.realms()
assert [item["realm"] for item in realms["realms"]] == ["pam", "pve"]
assert realms["default_realm"] == "pam"
assert auth.authenticate("admin", "secret", "pam") == {"ok": True, "user": "admin@pam"}

# Proxmox's partial ticket is a TFA challenge even without a separate flag.
auth._request = lambda path, fields=None: (
    {"ticket": "PVE:!tfa!partial-challenge", "username": "admin@pam"}
    if path == "/access/ticket" else REALMS
)
assert auth.authenticate("admin", "secret", "pam")["code"] == "TFA_REQUIRED"

auth._request = lambda path, fields=None: (
    {"need_tfa": 1} if path == "/access/ticket" else REALMS
)
assert auth.authenticate("admin", "secret", "pam")["code"] == "TFA_REQUIRED"

auth, _ = make_auth(permission={"/": {"Sys.Audit": 1}})
auth._request = lambda path, fields=None: (
    {"ticket": "discarded", "username": "admin@pam"} if path == "/access/ticket" else REALMS
)
assert auth.authenticate("admin", "secret", "pam")["code"] == "LOGIN_UNAUTHORIZED"

auth._request = lambda path, fields=None: (_ for _ in ()).throw(server.ProxmoxAuthError())
assert auth.authenticate("admin", "secret", "pam")["code"] == "LOGIN_FAILED"

auth._request = lambda path, fields=None: REALMS
assert auth.authenticate("admin", "secret", "unknown")["code"] == "LOGIN_FAILED"

# Proxmox usernames are not restricted by the legacy local-PAM regex.
auth, _ = make_auth()
auth._request = lambda path, fields=None: (
    {"ticket": "PVE:discarded-test-ticket", "username": "1admin@pve"}
    if path == "/access/ticket" else REALMS
)
assert auth.authenticate("1admin", "secret", "pve")["ok"] is True
assert auth.authenticate("bad\nname", "secret", "pve")["code"] == "LOGIN_FAILED"
assert auth.authenticate("bad\x00name", "secret", "pve")["code"] == "LOGIN_FAILED"
assert auth.authenticate("x" * 129, "secret", "pve")["code"] == "LOGIN_FAILED"

# Authorization and role results are cached per userid for the TTL.
auth, calls = make_auth()
assert auth.authorized("admin@pam") is True
assert auth.authorized("admin@pam") is True
assert calls == {"permissions": 1, "roles": 1}
assert auth.authorized("other@pam") is True
assert calls == {"permissions": 2, "roles": 1}

# Expired entries force fresh lookups and never reuse a stale allow decision.
auth, calls = make_auth()
clock = iter((100.0, 100.0, 131.0, 131.0, 131.0))
old_monotonic = server.time.monotonic
server.time.monotonic = lambda: next(clock)
try:
    assert auth.authorized("admin@pam") is True
    assert auth.authorized("admin@pam") is True
    assert calls == {"permissions": 1, "roles": 1}
    def revoked_permissions(args):
        if "/access/permissions" in args:
            calls["permissions"] += 1
            return {"/": {"Sys.Audit": 1}}
        calls["roles"] += 1
        return ROLE

    auth._pvesh_json = revoked_permissions
    assert auth.authorized("admin@pam") is False
    assert calls["permissions"] == 2
finally:
    server.time.monotonic = old_monotonic

# A failed refresh raises/fails closed rather than returning the stale allow.
auth, _ = make_auth()
assert auth.authorized("admin@pam") is True
auth._authorization_cache["admin@pam"] = (0, True)
auth._pvesh_json = lambda args: (_ for _ in ()).throw(server.ProxmoxAuthError())
try:
    auth.authorized("admin@pam")
except server.ProxmoxAuthError:
    pass
else:
    raise AssertionError("expired authorization failure did not fail closed")

# Rate limiting returns a structured result instead of None.
store = server.AuthStore(Path("/tmp/does-not-exist-uu-auth-test.json"))
store.backend = "internal"
store.realms = lambda: {"realms": [{"realm": "internal"}], "default_realm": "internal"}
store.verify = lambda username, password: False
for _ in range(5):
    assert store.login("admin", "wrong", "internal", "test-client")["code"] == "LOGIN_FAILED"
limited = store.login("admin", "wrong", "internal", "test-client")
assert limited["ok"] is False
assert limited["code"] == "LOGIN_RATE_LIMITED"
assert not store.sessions

print("web Proxmox auth tests: PASS")
