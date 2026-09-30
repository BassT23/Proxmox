#!/usr/bin/env python3
"""Regression tests for the explicitly authorized PAM Web UI user."""

import importlib.util
import os
import tempfile
from pathlib import Path

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_web", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def check_pam_user(configured, username, pam_result, expected):
    previous_user = os.environ.get("WEB_UI_PAM_USER")
    previous_backend = os.environ.get("UU_AUTH_BACKEND")
    try:
        if configured is None:
            os.environ.pop("WEB_UI_PAM_USER", None)
        else:
            os.environ["WEB_UI_PAM_USER"] = configured
        os.environ["UU_AUTH_BACKEND"] = "pam"
        calls = []
        old_pam = server.pam_authenticate
        server.pam_authenticate = lambda user, password: (calls.append((user, password)) or pam_result)
        try:
            auth = server.AuthStore(Path("/tmp/unused-web-auth.json"))
            assert auth.verify(username, "secret") is expected
        finally:
            server.pam_authenticate = old_pam
        should_call = bool(expected or (configured is not None and username == configured
                                        and server.USER_RE.fullmatch(configured)))
        assert bool(calls) is should_call
    finally:
        if previous_user is None:
            os.environ.pop("WEB_UI_PAM_USER", None)
        else:
            os.environ["WEB_UI_PAM_USER"] = previous_user
        if previous_backend is None:
            os.environ.pop("UU_AUTH_BACKEND", None)
        else:
            os.environ["UU_AUTH_BACKEND"] = previous_backend


check_pam_user(None, "root", True, True)
check_pam_user(None, "admin", True, False)
check_pam_user("admin", "admin", True, True)
check_pam_user("admin", "admin", False, False)
check_pam_user("admin", "root", True, False)
check_pam_user("admin", "otheruser", True, False)
check_pam_user("bad user", "bad user", True, False)
check_pam_user("", "root", True, False)
check_pam_user("admin;touch /tmp/pwned", "admin;touch /tmp/pwned", True, False)

with tempfile.TemporaryDirectory() as directory:
    os.environ["UU_AUTH_BACKEND"] = "internal"
    os.environ["WEB_UI_PAM_USER"] = "admin"
    old_pam = server.pam_authenticate
    server.pam_authenticate = lambda *_: (_ for _ in ()).throw(AssertionError("PAM used for internal backend"))
    try:
        auth = server.AuthStore(Path(directory) / "auth.json")
        assert auth.backend == "internal"
        assert auth.verify("anything", "secret") is False
    finally:
        server.pam_authenticate = old_pam
        os.environ.pop("UU_AUTH_BACKEND", None)
        os.environ.pop("WEB_UI_PAM_USER", None)

print("web PAM auth tests: PASS")
