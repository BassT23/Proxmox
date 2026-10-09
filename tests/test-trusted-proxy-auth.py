#!/usr/bin/env python3
"""TP-01: a shared NAT address alone cannot authenticate a proxy identity."""
import http.client
import os
from http.server import ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
from threading import Thread

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web-ui"))
import server as updater  # noqa: E402

PROOF = "A" * 48
HEADER = "X-UU-Gateway-Assertion"


def test_sso(trusted_cidr, include_identity=True, allowed="operator@example.com",
             proof=PROOF, secret_mode=0o600, file_enabled=True, symlink=False):
    environ = ("UU_AUTH_BACKEND", "UU_TRUSTED_PROXY_CIDRS",
               "UU_TRUSTED_PROXY_ALLOWED_USERS", "UU_TRUSTED_PROXY_ASSERTION_FILE")
    old = {name: os.environ.get(name) for name in environ}
    with tempfile.TemporaryDirectory(prefix="uu-proxy-test-") as tmp:
        assertion_file = Path(tmp) / "gateway.key"
        assertion_file.write_text(PROOF + "\n", encoding="ascii")
        assertion_file.chmod(secret_mode)
        if symlink:
            actual_file = Path(tmp) / "real.key"
            assertion_file.rename(actual_file)
            assertion_file.symlink_to(actual_file)
        try:
            os.environ.update({
                "UU_AUTH_BACKEND": "trusted_proxy",
                "UU_TRUSTED_PROXY_CIDRS": trusted_cidr,
                "UU_TRUSTED_PROXY_ALLOWED_USERS": allowed,
                "UU_TRUSTED_PROXY_ASSERTION_FILE": str(assertion_file) if file_enabled else "",
            })
            auth = updater.AuthStore(Path(tmp) / "unused-native-auth")
            httpd = ThreadingHTTPServer(("127.0.0.1", 0), updater.StatusHandler)
            httpd.auth = auth
            httpd.tls_enabled = False
            from types import SimpleNamespace
            httpd.interactive_broker = SimpleNamespace(detach_owner=lambda _: None)
            thread = Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                def call(path, identity="operator@example.com", cookie=None, csrf=None,
                         forwarded=None, method="GET", duplicate_proof=False):
                    headers = {}
                    if include_identity and identity is not None:
                        headers["Remote-User"] = identity
                    if proof is not None:
                        headers[HEADER] = proof
                    if cookie:
                        headers["Cookie"] = cookie
                    if csrf:
                        headers["X-CSRF-Token"] = csrf
                    if forwarded:
                        headers["X-Forwarded-For"] = forwarded
                    conn = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
                    conn.putrequest(method, path)
                    for name, value in headers.items():
                        conn.putheader(name, value)
                    if duplicate_proof:
                        conn.putheader(HEADER, "B" * 48)
                    conn.endheaders()
                    res = conn.getresponse()
                    import json
                    data = json.loads(res.read())
                    status = res.status
                    set_cookie = res.getheader("Set-Cookie")
                    conn.close()
                    return status, data, set_cookie

                status, session, cookie = call("/api/session")
                valid = (trusted_cidr == "127.0.0.1/32" and include_identity and allowed
                         and proof == PROOF and secret_mode == 0o600 and file_enabled and not symlink)
                if not valid:
                    assert status in (401, 503), (status, session)
                    return
                assert status == 200, (status, session)
                assert session["username"] == "operator@example.com"
                assert session["csrf"] and cookie and "HttpOnly" in cookie and "SameSite=Lax" in cookie
                cookie = cookie.split(";", 1)[0]
                assert call("/api/session", cookie=cookie)[0] == 200
                assert call("/api/session", cookie=cookie, duplicate_proof=True)[0] == 401
                assert call("/api/session", cookie=cookie, identity="intruder@example.com")[0] == 401
                assert call("/api/status", cookie=cookie, identity=None)[0] == 401
                assert call("/api/status", cookie=cookie, identity="intruder@example.com")[0] == 401
                assert call("/api/logout", cookie=cookie, method="POST")[0] == 403
                assert call("/api/logout", cookie=cookie, csrf="wrong-token", method="POST")[0] == 403
                assert call("/api/logout", cookie=cookie, csrf=session["csrf"], method="POST")[0] == 200
                assert call("/api/session")[0] == 200
                assertion_file.chmod(0o644)
                assert call("/api/session")[0] in (401, 503)
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


from types import SimpleNamespace
read_only_handler = SimpleNamespace(
    server=SimpleNamespace(),
    headers=SimpleNamespace(get=lambda name, default="": default),
)
assert updater.StatusHandler.current_session(read_only_handler) is None

test_sso("127.0.0.1/32")
test_sso("192.0.2.0/24")
test_sso("127.0.0.1/32", include_identity=False)
test_sso("127.0.0.1/32", allowed="")
test_sso("127.0.0.1/32", proof=None)
test_sso("127.0.0.1/32", proof="B" * 48)
test_sso("127.0.0.1/32", secret_mode=0o644)
test_sso("127.0.0.1/32", file_enabled=False)
test_sso("127.0.0.1/32", symlink=True)
print("trusted proxy auth tests: PASS")
