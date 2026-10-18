#!/usr/bin/env python3
"""Regression coverage for the authenticated WebUI API management page."""

import http.client
import importlib.util
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import tempfile
from threading import Thread
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
import sys

sys.path.insert(0, str(ROOT / "web-ui"))
import api_tokens  # noqa: E402


SPEC = importlib.util.spec_from_file_location("ultimate_updater_web_management", ROOT / "web-ui" / "server.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


class FixtureHandler(WEB.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.command_calls.append(list(args))
        raise AssertionError("API management must not execute external commands")


def request(server, method, path, headers=None, payload=None):
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    request_headers = dict(headers or {})
    body = None
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    connection.request(method, path, body=body, headers=request_headers)
    response = connection.getresponse()
    data = json.loads(response.read())
    connection.close()
    return response.status, data


def request_page(server, path):
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    connection.request("GET", path)
    response = connection.getresponse()
    body = response.read().decode("utf-8")
    connection.close()
    return response.status, body


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    token_file = root / "api-tokens.json"
    token_id, secret = api_tokens.create_token(token_file, "existing", ["read", "logs"])
    api_tokens.set_enabled(token_file, True)
    session_token = "web-session"
    session = {"user": "root@pam", "csrf": "csrf-fixture", "expires": 4102444800}

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    httpd.api_token_file = token_file
    httpd.status_api_token_file = token_file
    httpd.tls_enabled = True
    httpd.public_origin = None
    httpd.trusted_proxy_networks = ()
    httpd.auth = SimpleNamespace(
        configured=True,
        session=lambda value: session if value == session_token else None,
    )
    httpd.command_calls = []
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        status, page = request_page(httpd, "/api")
        assert status == 200
        assert 'id="api-page"' in page
        assert '<span>API</span>' in page
        assert '<span>Logs</span>' not in page

        status, body = request(httpd, "GET", "/api/api-management")
        assert status == 401
        assert body["error"]["code"] == "AUTH_REQUIRED"

        auth_headers = {"Cookie": f"UU_SESSION={session_token}"}
        status, body = request(httpd, "GET", "/api/api-management", auth_headers)
        assert status == 200
        assert body["api_version"] == 1
        assert body["schema_version"] == 1
        assert body["api"]["state"] == "enabled"
        assert body["api"]["https_required"] is True
        assert body["api"]["endpoint"].startswith("https://127.0.0.1:")
        assert body["permissions"] == ["read", "logs", "check", "update", "reboot", "cancel"]
        assert body["tokens"] == [{
            "id": token_id,
            "name": "existing",
            "permissions": ["read", "logs"],
            "expires_at": None,
            "revoked": False,
        }]
        assert secret not in json.dumps(body)
        assert "hash" not in json.dumps(body)

        csrf_headers = {**auth_headers, "X-CSRF-Token": session["csrf"]}
        status, body = request(
            httpd, "POST", "/api/api-tokens", auth_headers,
            {"name": "rejected", "permissions": ["read"]},
        )
        assert status == 403
        assert body["error"]["code"] == "CSRF_REJECTED"
        assert len(api_tokens.load_config(token_file)["tokens"]) == 1

        status, body = request(
            httpd, "POST", "/api/api-tokens", csrf_headers,
            {"name": "created", "permissions": ["read", "check"], "expires_at": None},
        )
        assert status == 201
        created_secret = body["token"]
        created_id = body["token_id"]
        assert isinstance(created_secret, str) and created_secret
        assert body["metadata"] == {
            "id": created_id,
            "name": "created",
            "permissions": ["read", "check"],
            "expires_at": None,
            "revoked": False,
        }
        stored = token_file.read_text(encoding="utf-8")
        assert created_secret not in stored
        assert api_tokens.hash_token(created_secret) in stored

        status, body = request(httpd, "GET", "/api/api-management", auth_headers)
        assert status == 200
        assert {item["id"] for item in body["tokens"]} == {token_id, created_id}
        assert created_secret not in json.dumps(body)
        assert "hash" not in json.dumps(body)

        status, body = request(httpd, "DELETE", f"/api/api-tokens/{created_id}", csrf_headers)
        assert status == 200
        assert body["message"] == "Token revoked."
        revoked = next(item for item in api_tokens.load_config(token_file)["tokens"] if item["id"] == created_id)
        assert revoked["revoked"] is True

        status, body = request(
            httpd, "POST", "/api/api-tokens", csrf_headers,
            {"name": "invalid", "permissions": ["logs"]},
        )
        assert status == 422
        assert body["error"]["code"] == "API_TOKEN_NOT_CREATED"

        token_file.write_text("{ invalid", encoding="utf-8")
        status, body = request(httpd, "GET", "/api/api-management", auth_headers)
        assert status == 200
        assert body["api"]["state"] == "invalid"
        assert body["api"]["enabled"] is None
        assert body["tokens"] == []
        assert not httpd.command_calls
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=3)

print("WebUI API management regression tests: PASS")
