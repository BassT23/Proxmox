#!/usr/bin/env python3
"""TP-01: fail-closed reverse proxy login without native password submission."""
import http.client
import os
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
from threading import Thread

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web-ui"))
import server as updater  # noqa: E402


def test_sso(trusted_cidr, include_identity=True, allowed="operator@example.com"):
    environ = ("UU_AUTH_BACKEND", "UU_TRUSTED_PROXY_CIDRS", "UU_TRUSTED_PROXY_ALLOWED_USERS")
    old = {name: os.environ.get(name) for name in environ}
    try:
        os.environ.update({
            "UU_AUTH_BACKEND": "trusted_proxy",
            "UU_TRUSTED_PROXY_CIDRS": trusted_cidr,
            "UU_TRUSTED_PROXY_ALLOWED_USERS": allowed,
        })
        auth = updater.AuthStore(Path("/tmp/unused-native-auth"))
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), updater.StatusHandler)
        httpd.auth = auth
        httpd.tls_enabled = False
        from types import SimpleNamespace
        httpd.interactive_broker = SimpleNamespace(detach_owner=lambda _: None)
        thread = Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            def call(path, identity="operator@example.com", cookie=None, csrf=None, forwarded=None, method="GET"):
                headers = {}
                if include_identity and identity is not None:
                    headers["Remote-User"] = identity
                if cookie:
                    headers["Cookie"] = cookie
                if csrf:
                    headers["X-CSRF-Token"] = csrf
                if forwarded:
                    headers["X-Forwarded-For"] = forwarded
                conn = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
                conn.request(method, path, headers=headers)
                res = conn.getresponse()
                data = res.read()
                status = res.status
                set_cookie = res.getheader("Set-Cookie")
                conn.close()
                import json
                return status, json.loads(data), set_cookie

            status, session, cookie = call("/api/session")
            if trusted_cidr != "127.0.0.1/32" or not include_identity or not allowed:
                assert status in (401, 503), (status, session)
                return
            assert status == 200, (status, session)
            assert session["username"] == "operator@example.com"
            assert session["csrf"] and cookie and "HttpOnly" in cookie and "SameSite=Lax" in cookie
            cookie = cookie.split(";", 1)[0]
            assert call("/api/session", cookie=cookie)[0] == 200
            assert call("/api/session", cookie=cookie, identity="intruder@example.com")[0] == 401
            assert call("/api/status", cookie=cookie, identity=None)[0] == 401
            assert call("/api/status", cookie=cookie, identity="intruder@example.com")[0] == 401
            assert call("/api/logout", cookie=cookie, method="POST")[0] == 403
            assert call("/api/logout", cookie=cookie, csrf="wrong-token", method="POST")[0] == 403
            # Existing CSRF and origin checks protect all state-changing operations.
            assert call("/api/logout", cookie=cookie, csrf=session["csrf"], method="POST")[0] == 200
            # Proxy SSO can issue another fresh local session after local logout.
            assert call("/api/session")[0] == 200
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=3)
    finally:
        for name, value in old.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


test_sso("127.0.0.1/32")
test_sso("192.0.2.0/24")
test_sso("127.0.0.1/32", include_identity=False)
test_sso("127.0.0.1/32", allowed="")
print("trusted proxy auth tests: PASS")
