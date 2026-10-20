#!/usr/bin/env python3
"""Regression coverage for the bounded, read-only API-v1 status summary."""

from datetime import datetime, timedelta, timezone
import http.client
import importlib.util
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import secrets
import sys
import tempfile
from threading import Thread
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import api_tokens  # noqa: E402

SPEC = importlib.util.spec_from_file_location("ultimate_updater_status_summary", ROOT / "web-ui" / "server.py")
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


class NoActionHandler(web.StatusHandler):
    def schedule_remote_reconciliation(self):
        raise AssertionError("status summary polling must not schedule reconciliation")

    def run_command(self, *args, **kwargs):
        raise AssertionError("status summary polling must not execute commands")


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


now = datetime.now(timezone.utc).replace(microsecond=0)
current = stamp(now)


def record(status="ok", reachable=True, updates=0, reboot=False):
    return {
        "id": "fixture-target",
        "check_status": status,
        "reachable": reachable,
        "updates": {"available": updates},
        "reboot_required": reboot,
    }


complete = {"schema_version": 1, "generated_at": current,
            "targets": [record(updates=2), record(updates=3, reboot=True)]}
summary = web.build_status_summary(complete, now=now)
assert summary["state"] == "current"
assert summary["targets"] == {
    "total": 2, "reachable": 2, "unreachable": 0, "checked": 2,
    "unknown": 0, "failed": 0, "unknown_updates": 0, "unknown_reboot": 0,
}
assert summary["updates_available"] == 5
assert summary["reboot_required"] == 1

partial = {"schema_version": 1, "generated_at": current,
           "targets": [record(updates=2), record(status="error", reachable=False,
                                                 updates=None, reboot=None)]}
partial_summary = web.build_status_summary(partial, now=now)
assert partial_summary["targets"]["checked"] == 1
assert partial_summary["targets"]["failed"] == 1
assert partial_summary["targets"]["unreachable"] == 1
assert partial_summary["updates_available"] is None
assert partial_summary["reboot_required"] is None

unknown = {"schema_version": 1, "generated_at": current,
           "targets": [record(updates=2), record(status="not_checked", reachable=None,
                                                 updates=None, reboot=None)]}
unknown_summary = web.build_status_summary(unknown, now=now)
assert unknown_summary["targets"]["unknown"] == 1
assert unknown_summary["updates_available"] is None
assert unknown_summary["reboot_required"] is None

malformed_target = {"schema_version": 1, "generated_at": current,
                    "targets": [{"reachable": {}, "check_status": [],
                                  "updates": {"available": 9}, "reboot_required": True}]}
malformed_summary = web.build_status_summary(malformed_target, now=now)
assert malformed_summary["targets"]["unknown"] == 1
assert malformed_summary["updates_available"] is None
assert malformed_summary["reboot_required"] is None

stale = {**complete, "generated_at": stamp(now - timedelta(days=2))}
stale_summary = web.build_status_summary(stale, now=now)
assert stale_summary["state"] == "stale"
assert stale_summary["updates_available"] is None
assert stale_summary["reboot_required"] is None

missing_timestamp = {"schema_version": 1, "targets": complete["targets"]}
unknown_document = web.build_status_summary(missing_timestamp, now=now)
assert unknown_document["state"] == "unknown"
assert unknown_document["updates_available"] is None
assert unknown_document["reboot_required"] is None

empty = web.build_status_summary({"schema_version": 1, "generated_at": current, "targets": []}, now=now)
assert empty["targets"]["total"] == 0
assert empty["updates_available"] is None
assert empty["reboot_required"] is None

try:
    web.build_status_summary({"schema_version": 2, "generated_at": current, "targets": []}, now=now)
except web.StatusSummaryDataError:
    pass
else:
    raise AssertionError("wrong status schema must fail closed")


def request(server, path, token=None, headers=None, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    request_headers = dict(headers or {})
    if token is not None:
        request_headers["Authorization"] = "Bearer " + token
    connection.request(method, path, headers=request_headers)
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def duplicate_authorization(server, token):
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
    connection.putrequest("GET", "/api/v1/status-summary")
    connection.putheader("Authorization", "Bearer " + token)
    connection.putheader("Authorization", "Bearer " + token)
    connection.endheaders()
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    status_file = root / "status.json"
    token_file = root / "api-tokens.json"
    token = secrets.token_urlsafe(32)
    _, generated_token = api_tokens.create_token(token_file, "summary", ["read"])
    token = generated_token
    api_tokens.set_enabled(token_file, True)
    token_file.chmod(0o600)
    status_file.write_text(json.dumps(complete), encoding="utf-8")

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), NoActionHandler)
    httpd.status_file = status_file
    httpd.api_token_file = token_file
    httpd.status_api_token_file = token_file
    httpd.status_api_max_age_seconds = 86400
    httpd.tls_enabled = True
    httpd.auth = SimpleNamespace(configured=True, session=lambda _: None)
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        status, payload = request(httpd, "/api/v1/status-summary", token=token)
        assert status == 200
        assert payload["api_version"] == 1
        assert payload["schema_version"] == 1
        assert payload["state"] == "current"
        assert payload["stale"] is False
        assert payload["summary"]["checked"] == 2
        assert payload["updates_available"] == 5
        assert payload["reboot_required"] == 1
        assert "fixture-target" not in json.dumps(payload)

        for headers in (
            {},
            {"Authorization": "Bearer " + ("A" * 43)},
            {"Authorization": "Bearer"},
            {"Authorization": "Basic " + token},
        ):
            status, payload = request(httpd, "/api/v1/status-summary", headers=headers)
            assert status == 401, (headers, status, payload)
        status, _ = duplicate_authorization(httpd, token)
        assert status == 401
        status, _ = request(httpd, "/api/v1/status-summary", token=token,
                            headers={"Cookie": "UU_SESSION=browser"})
        assert status == 401
        status, _ = request(httpd, "/api/v1/update/fixture-target", token=token, method="POST")
        assert status == 403
        status, payload = request(httpd, "/api/v1/status-summary", token=token, method="POST")
        assert status == 405 and payload["error"]["code"] == "METHOD_NOT_ALLOWED"

        status, payload = request(httpd, "/api/v1/status-summary")
        assert status == 401 and payload["error"]["code"] == "AUTH_REQUIRED"

        status_file.unlink()
        status, payload = request(httpd, "/api/v1/status-summary", token=token)
        assert status == 404 and payload["error"]["code"] == "STATUS_NOT_FOUND"

        status_file.write_text("{broken", encoding="utf-8")
        status, payload = request(httpd, "/api/v1/status-summary", token=token)
        assert status == 422 and payload["error"]["code"] == "STATUS_INVALID"

        status_file.write_text(json.dumps({"schema_version": 2, "generated_at": current, "targets": []}),
                               encoding="utf-8")
        status, payload = request(httpd, "/api/v1/status-summary", token=token)
        assert status == 422 and payload["error"]["code"] == "STATUS_INVALID"
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=3)

print("API v1 status summary regression tests: PASS")
