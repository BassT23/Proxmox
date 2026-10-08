#!/usr/bin/env python3
"""US-API-01: isolated status summary consumer must never launch update code."""
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
from threading import Thread
from http.server import ThreadingHTTPServer
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web-ui"))
import server as updater  # noqa: E402


def exercise(status, token_content="fixture-secret-not-for-production", configured=True, credential_mode=0o600):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        status_path = root / "status.json"
        if status is not None:
            status_path.write_text(json.dumps(status))
        credential = root / "status-token"
        credential.write_text(token_content)
        credential.chmod(credential_mode)
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), updater.StatusHandler)
        httpd.status_file = status_path
        httpd.status_api_token_file = credential if configured else None
        httpd.status_api_max_age_seconds = 86400
        thread = Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            def request(path, token=None, method="GET"):
                connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
                headers = {"Authorization": "Bearer " + token} if token else {}
                connection.request(method, path, headers=headers)
                response = connection.getresponse()
                raw = response.read()
                connection.close()
                return response.status, json.loads(raw)

            if not configured:
                code, payload = request("/api/status-summary")
                assert code == 503, (code, payload)
                return None
            if credential_mode != 0o600:
                code, payload = request("/api/status-summary", token=token_content)
                assert code == 503, (code, payload)
                return code, payload
            deny_status, denied = request("/api/status-summary")
            assert deny_status == 401, (deny_status, denied)
            assert "fixture-secret" not in str(denied)
            invalid_status, invalid = request("/api/status-summary", token="wrong-credential")
            assert invalid_status == 401, (invalid_status, invalid)
            method_status, _ = request("/api/status-summary", token=token_content, method="POST")
            assert method_status != 200
            return request("/api/status-summary", token=token_content)
        finally:
            httpd.shutdown()
            httpd.server_close()
            thread.join(timeout=3)


now = datetime.now(timezone.utc)
stamp = now.isoformat()
status = {
    "schema_version": 1, "generated_at": stamp, "targets": [
        {"id": "host:node", "reachable": True, "check_status": "ok", "updates": {"available": 4}, "reboot_required": False},
        {"id": "912", "reachable": True, "check_status": "updates_available", "updates": {"available": 2}, "reboot_required": True},
    ]
}
code, payload = exercise(status)
assert code == 200, (code, payload)
assert payload["schema_version"] == 1
assert payload["state"] == "current"
assert payload["targets"]["total"] == 2
assert payload["targets"]["reachable"] == 2
assert payload["targets"]["failed"] == 0
assert payload["updates_available"] == 6
assert payload["reboot_required"] == 1
assert payload["generated_at"] == stamp
assert "host:node" not in str(payload), payload

unknown = json.loads(json.dumps(status))
unknown["targets"][1]["updates"]["available"] = None
unknown["targets"][1]["reboot_required"] = None
code, payload = exercise(unknown)
assert code == 200
assert payload["updates_available"] is None
assert payload["reboot_required"] is None
assert payload["targets"]["unknown_updates"] == 1

partial = json.loads(json.dumps(status))
partial["targets"][1]["check_status"] = "error"
partial["targets"][1]["reachable"] = False
code, payload = exercise(partial)
assert code == 200
assert payload["targets"]["failed"] == 1
assert payload["targets"]["unreachable"] == 1

stale = json.loads(json.dumps(status))
stale["generated_at"] = (now - timedelta(days=3)).isoformat()
code, payload = exercise(stale)
assert code == 200
assert payload["state"] == "stale"

assert exercise(None)[0] == 404
assert exercise({"schema_version": 1, "targets": "wrong"})[0] == 422
assert exercise(status, configured=False) is None
print("status summary API tests: PASS")

insecure_code, insecure_payload = exercise(status, credential_mode=0o644)
assert insecure_code == 503, (insecure_code, insecure_payload)
