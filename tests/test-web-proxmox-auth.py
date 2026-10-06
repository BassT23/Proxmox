#!/usr/bin/env python3
"""Regression tests for Proxmox-native Web UI authentication."""

import importlib.util
import json
import threading
import time
from pathlib import Path
from urllib.parse import quote


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

# The generic Proxmox challenge flow keeps the signed partial ticket internal
# and sends the factor response in password when tfa-challenge is present.
partial = "PVE:!tfa!" + quote('{"type":"tfa"}', safe="")
complete_calls = []
auth, _ = make_auth()
def challenge_request(path, fields=None):
    if path == "/access/domains":
        return REALMS
    if path == "/access/ticket":
        complete_calls.append(fields)
        if fields and fields.get("tfa-challenge"):
            return {"ticket": "PVE:complete-ticket", "username": "admin@pam"}
        return {"ticket": partial, "username": "admin@pam"}
    raise AssertionError(f"unexpected API request: {path}")
auth._request = challenge_request
started = auth.authenticate("admin", "secret", "pam")
assert started["code"] == "TFA_REQUIRED"
assert started["challenge"]["methods"] == ["totp"]
assert started["challenge"]["partial_ticket"] == partial
assert auth.complete_tfa("admin", "pam", partial, "totp", "123456")["ok"] is True
assert complete_calls[-1]["password"] == "totp:123456"
assert complete_calls[-1]["tfa-challenge"] == partial

# WebAuthn uses the same Proxmox partial-ticket flow. The browser receives only
# the public options; the signed partial ticket stays in the server-side state.
webauthn_public = {
    "webauthn": {"publicKey": {
        "challenge": "public-challenge",
        "rpId": "proxmox-test-2.internal",
        "allowCredentials": [{"type": "public-key", "id": "credential-id"}],
        "userVerification": "discouraged",
    }}
}
webauthn_partial = "PVE:!tfa!" + quote(json.dumps(webauthn_public, separators=(",", ":")), safe="") + ":signature"
webauthn_calls = []
auth, _ = make_auth()
def webauthn_request(path, fields=None, request_host=None, request_origin=None):
    if path == "/access/domains":
        return REALMS
    if path == "/access/ticket":
        webauthn_calls.append((fields, request_host, request_origin))
        if fields and fields.get("tfa-challenge"):
            return {"ticket": "PVE:complete-webauthn-ticket", "username": "admin@pam"}
        return {"ticket": webauthn_partial, "username": "admin@pam"}
    raise AssertionError(f"unexpected API request: {path}")
auth._request = webauthn_request
webauthn_started = auth.authenticate("admin", "secret", "pam", "proxmox-test-2.internal:8765",
                                     "https://proxmox-test-2.internal:8765")
assert webauthn_started["challenge"]["methods"] == ["webauthn"]
assert webauthn_started["challenge"]["public_challenge"] == webauthn_public
assert auth.complete_tfa("admin", "pam", webauthn_partial, "webauthn",
                         json.dumps({"id": "id", "type": "public-key", "challenge": "public",
                                     "rawId": "raw", "response": {"authenticatorData": "a",
                                     "clientDataJSON": "b", "signature": "c"}}),
                         "proxmox-test-2.internal:8765",
                         "https://proxmox-test-2.internal:8765")["ok"] is True
assert webauthn_calls[-1][0]["password"].startswith("webauthn:{")
assert webauthn_calls[-1][0]["tfa-challenge"] == webauthn_partial
assert webauthn_calls[-1][1:] == ("proxmox-test-2.internal:8765", "https://proxmox-test-2.internal:8765")

# An AuthStore exposes only an opaque challenge id to the caller and creates
# the Ultimate Updater session only after Proxmox returns a complete ticket.
auth, _ = make_auth()
auth._request = challenge_request
store = server.AuthStore(Path("/tmp/unused-proxmox-tfa-test.json"))
store.backend = "proxmox"
store.proxmox = auth
pending = store.login("admin", "secret", "pam", "127.0.0.1")
assert pending["code"] == "TFA_REQUIRED"
assert "partial_ticket" not in pending
assert pending["challenge_id"] in store.tfa_challenges
assert pending["_tfa_binding"] not in pending["challenge_id"]
assert store.complete_tfa(pending["challenge_id"], "totp", "123456", "wrong-binding")["code"] == "TFA_EXPIRED"
assert pending["challenge_id"] in store.tfa_challenges
session = store.complete_tfa(pending["challenge_id"], "totp", "123456", pending["_tfa_binding"])
assert session["ok"] is True
assert pending["challenge_id"] not in store.tfa_challenges
assert store.session(session["token"])["user"] == "admin@pam"

# Challenges are client-bound and cannot be replayed after completion.
assert store.complete_tfa(pending["challenge_id"], "totp", "123456", pending["_tfa_binding"])["code"] == "TFA_EXPIRED"

# TFA challenges use bounded in-memory state and opportunistic cleanup, not a
# timer thread per pending login.
def tfa_store():
    item = server.AuthStore(Path("/tmp/unused-proxmox-tfa-limit-test.json"))
    item.backend = "proxmox"
    item.proxmox.authenticate = lambda username, password, realm, *_context: {
        "ok": False, "code": "TFA_REQUIRED", "message": "TFA required.",
        "challenge": {"username": f"{username}@{realm}", "realm": realm,
                       "partial_ticket": partial, "methods": ["totp"],
                       "public_challenge": {"totp": True}},
    }
    return item

threads_before = {thread.ident for thread in threading.enumerate()}
limited_store = tfa_store()
first = limited_store.login("admin", "secret", "pam", "client-a")
assert first["code"] == "TFA_REQUIRED"
assert "timer" not in limited_store.tfa_challenges[first["challenge_id"]]
assert len({thread.ident for thread in threading.enumerate()} - threads_before) == 0
second = limited_store.login("admin", "secret", "pam", "client-a")
assert second["code"] == "TFA_REQUIRED"
third = limited_store.login("admin", "secret", "pam", "client-a")
assert third["code"] == "TFA_RATE_LIMITED"
assert len(limited_store.tfa_challenges) == 2

global_store = tfa_store()
global_store.TFA_MAX_ACTIVE = 2
assert global_store.login("admin", "secret", "pam", "client-a")["code"] == "TFA_REQUIRED"
assert global_store.login("other", "secret", "pam", "client-b")["code"] == "TFA_REQUIRED"
assert global_store.login("third", "secret", "pam", "client-c")["code"] == "TFA_RATE_LIMITED"

# A different user can still start a parallel challenge, while repeated starts
# for one user are rate-limited even when old challenges are cancelled.
parallel_store = tfa_store()
assert parallel_store.login("admin", "secret", "pam", "client-a")["code"] == "TFA_REQUIRED"
assert parallel_store.login("other", "secret", "pam", "client-a")["code"] == "TFA_REQUIRED"
for _ in range(parallel_store.TFA_MAX_STARTS_PER_USER - 1):
    pending_start = parallel_store.login("admin", "secret", "pam", "client-b")
    assert pending_start["code"] == "TFA_REQUIRED"
    parallel_store.cancel_tfa(pending_start["challenge_id"], pending_start["_tfa_binding"])
assert parallel_store.login("admin", "secret", "pam", "client-c")["code"] == "TFA_RATE_LIMITED"

# Expiry is removed during the next authenticated operation without a timer.
expired_store = tfa_store()
expired = expired_store.login("admin", "secret", "pam", "client-a")
expired_store.tfa_challenges[expired["challenge_id"]]["expires"] = time.time() - 1
assert expired_store.login("other", "secret", "pam", "client-a")["code"] == "TFA_REQUIRED"
assert expired["challenge_id"] not in expired_store.tfa_challenges

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
