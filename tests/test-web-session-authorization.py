"""HTTP semantics for transient versus confirmed Proxmox authorization results."""

import http.client
import importlib.util
import json
import threading
from pathlib import Path


root = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)


class Auth:
    configured = True

    def __init__(self, result):
        self.result = result

    def session(self, token):
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


class PollingHandler(web.StatusHandler):
    def jobs(self):
        return []


def request(auth):
    server = web.ThreadingHTTPServer(("127.0.0.1", 0), PollingHandler)
    server.auth = auth
    server.tls_enabled = False
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
        connection.request("GET", "/api/session", headers={"Cookie": "UU_SESSION=test-token"})
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body
    finally:
        server.shutdown()
        server.server_close()


status, body = request(Auth(web.AuthorizationUnavailableError()))
assert status == 503
assert body["error"]["code"] == "AUTHORIZATION_UNAVAILABLE"

status, body = request(Auth(None))
assert status == 401
assert body["error"]["code"] == "AUTH_REQUIRED"

# A keep-alive connection may carry an unauthenticated bootstrap request
# before login and authenticated dashboard polling afterwards. Request-local
# handler state must not retain the initial ``None`` session across requests.
server = web.ThreadingHTTPServer(("127.0.0.1", 0), PollingHandler)
auth = Auth(None)
server.auth = auth
server.tls_enabled = False
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    connection.request("GET", "/api/session", headers={"Cookie": "UU_SESSION=test-token"})
    response = connection.getresponse()
    assert response.status == 401
    response.read()
    auth.result = {"user": "admin@pam", "csrf": "csrf", "expires": 9999999999}
    for path in ("/api/jobs", "/api/jobs", "/api/jobs"):
        connection.request("GET", path, headers={"Cookie": "UU_SESSION=test-token"})
        response = connection.getresponse()
        assert response.status != 401, f"valid polling request was rejected: {path}"
        response.read()
    connection.close()
finally:
    server.shutdown()
    server.server_close()

print("web session authorization HTTP tests: PASS")
