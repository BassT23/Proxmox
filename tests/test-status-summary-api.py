#!/usr/bin/env python3
"""US-API-01: isolated status summary consumer must never launch update code."""
import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
from threading import Thread
from http.server import ThreadingHTTPServer
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web-ui"))
import server as updater  # noqa: E402


def exercise(status, token_content="fixture-secret-not-for-production", configured=True, credential_mode=0o600, security_checks=False):
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
        # Fake native login without invoking PAM, Proxmox, jobs or update actions.
        httpd.auth = SimpleNamespace(
            configured=True,
            session=lambda token: {"user": "fixture-user", "csrf": "fixture-csrf"}
            if token == "fixture-session" else None,
        )
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

            def raw_request(path, header_pairs, method="GET"):
                """Send real duplicate headers and inert JSON POSTs over loopback."""
                connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
                try:
                    connection.putrequest(method, path)
                    for name, value in header_pairs:
                        connection.putheader(name, value)
                    if method == "POST":
                        connection.putheader("Content-Type", "application/json")
                        connection.putheader("Content-Length", "2")
                        connection.endheaders(b"{}")
                    else:
                        connection.endheaders()
                    response = connection.getresponse()
                    payload = json.loads(response.read())
                    return response.status, payload
                finally:
                    connection.close()

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
            if security_checks:
                valid = "Bearer " + token_content
                for bad in ("Bearer", "bearer " + token_content,
                            "Bearer  " + token_content, "Basic " + token_content):
                    code, _ = raw_request("/api/status-summary", [("Authorization", bad)])
                    assert code == 401, (bad.split(" ", 1)[0], code)
                code, _ = raw_request("/api/status-summary", [
                    ("Authorization", valid), ("Authorization", valid)])
                assert code == 401, ("duplicate Authorization", code)

                actual = root / "real-status-token"
                credential.replace(actual)
                credential.symlink_to(actual)
                try:
                    code, _ = request("/api/status-summary", token=token_content)
                    assert code == 503, ("symlink token file", code)
                finally:
                    credential.unlink()
                    actual.replace(credential)
                with patch.object(updater.os, "geteuid", return_value=os.geteuid() + 1):
                    code, _ = request("/api/status-summary", token=token_content)
                assert code == 503, ("wrong token-file owner", code)

                # Machine credentials cannot replace browser sessions or CSRF.
                for path in ("/api/session", "/api/status", "/api/jobs"):
                    code, _ = request(path, token=token_content)
                    assert code == 401, (path, code)
                code, _ = raw_request("/api/status-summary", [
                    ("Cookie", "UU_SESSION=fixture-session")])
                assert code == 401, ("browser cookie on machine endpoint", code)
                code, _ = raw_request("/api/update-all", [
                    ("Authorization", valid)], method="POST")
                assert code == 401, ("machine token on update action", code)
                code, _ = raw_request("/api/update-all", [
                    ("Cookie", "UU_SESSION=fixture-session"),
                    ("Authorization", valid)], method="POST")
                assert code == 403, ("native session without CSRF", code)
                code, _ = raw_request("/api/update-all", [
                    ("Cookie", "UU_SESSION=fixture-session"),
                    ("X-CSRF-Token", "fixture-csrf"),
                    ("Origin", "https://untrusted.invalid")], method="POST")
                assert code == 403, ("invalid Origin with native session", code)
                print("status summary API auth-boundary negative tests: PASS")
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
code, payload = exercise(status, security_checks=True)
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
