#!/usr/bin/env python3
"""Local HTTP regression coverage for the scoped, read-only integration API."""

from datetime import datetime, timedelta, timezone
import http.client
import importlib.util
import json
from pathlib import Path
import secrets
import stat
import sys
import tempfile
from http.server import ThreadingHTTPServer
from subprocess import CompletedProcess
from threading import Thread
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import api_tokens  # noqa: E402

SPEC = importlib.util.spec_from_file_location("ultimate_updater_web_api_v1", ROOT / "web-ui" / "server.py")
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


def token_record(token_id, name, token, permissions, expires_at=None, revoked=False):
    return {"id": token_id, "name": name, "hash": api_tokens.hash_token(token),
            "permissions": permissions, "expires_at": expires_at, "revoked": revoked}


class FixtureHandler(web.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.command_calls.append((list(args), timeout, extra_env or {}))
        if len(args) >= 2 and args[1] == "list":
            return CompletedProcess(args, 0, self.server.jobs_output, "")
        if args and args[0] == "journalctl":
            return CompletedProcess(args, 0, self.server.job_log, "")
        return CompletedProcess(args, 1, "", "unsupported fixture command")


class ApiFixture:
    def __init__(self, root):
        self.root = root
        self.status = root / "status.json"
        self.tokens = root / "api-tokens.json"
        self.runner = root / "job-runner.sh"
        self.config = root / "update.conf"
        self.update_script = root / "update.sh"
        self.status.write_text(json.dumps({
            "schema_version": 1,
            "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "targets": [
                {"id": "986", "name": "Windows <fixture>", "type": "vm", "node": "test-node",
                 "transport": "qga", "reachable": True, "os": "Windows Server 2025",
                 "updater": "windows-update", "check_status": "ok", "last_check": "2026-10-17T10:00:00Z",
                 "updates": {"available": 0}, "normal_updates": None, "security_updates": None,
                 "security_split_supported": False, "reboot_required": False,
                 "last_update": {"status": "success", "result_code": 2, "processed": 5,
                                 "job_id": "ultimate-updater-update-986-fixture"},
                 "windows_update": {"source": "Windows Update Agent", "queried_at": "2026-10-17T10:00:00Z",
                                    "history": [{"date": "2026-10-17", "kb": "KB1234567",
                                                 "title": "Title <escaped>", "operation": "Installation",
                                                 "result": "Succeeded", "result_code": 2, "hresult": "0x00000000"}]}},
                {"id": "100", "name": "Linux fixture", "type": "lxc", "node": "test-node",
                 "transport": "ssh", "reachable": None, "os": "Debian", "updater": "apt",
                 "check_status": "not_checked", "last_check": None, "updates": {"available": None},
                 "reboot_required": None, "skip_reason": {
                     "code": "STOPPED_READ_ONLY",
                     "message": "LXC 100 is stopped; <fixture> remains escaped data",
                 }},
            ],
        }), encoding="utf-8")
        self.runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.runner.chmod(0o750)
        self.config.write_text('USED_BRANCH="develop"\n', encoding="utf-8")
        self.update_script.write_text('VERSION="5.2"\n', encoding="utf-8")
        self.update_script.chmod(0o750)
        self.jobs_output = (
            "ultimate-updater-check-986-fixture\t986\tcompleted\t"
            "2026-10-17T10:00:00Z\t2026-10-17T10:00:01Z\t0\tcheck\t\tfalse\tfalse\n"
        )
        self.job_log = "safe fixture log\n"
        self.read_token = secrets.token_urlsafe(32)
        self.logs_token = secrets.token_urlsafe(32)
        self.expired_token = secrets.token_urlsafe(32)
        self.revoked_token = secrets.token_urlsafe(32)
        # Rewrite now that token attributes are initialized.
        self.tokens.write_text(json.dumps({
            "version": 1, "enabled": True,
            "tokens": [
                token_record("read", "read-fixture", self.read_token, ["read"]),
                token_record("logs", "logs-fixture", self.logs_token, ["read", "logs"]),
                token_record("expired", "expired", self.expired_token, ["read"], "2000-01-01T00:00:00Z"),
                token_record("revoked", "revoked", self.revoked_token, ["read"], revoked=True),
            ],
        }), encoding="utf-8")
        self.tokens.chmod(0o600)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        self.httpd.status_file = self.status
        self.httpd.api_token_file = self.tokens
        self.httpd.status_api_token_file = self.tokens
        self.httpd.status_api_max_age_seconds = 86400
        self.httpd.tls_enabled = True
        self.httpd.job_runner = self.runner
        self.httpd.jobs_dir = self.root / "jobs"
        self.httpd.jobs_dir.mkdir()
        self.httpd.config_file = self.config
        self.httpd.update_script = self.update_script
        self.httpd.version_last_data = None
        self.httpd.command_calls = []
        self.httpd.jobs_output = self.jobs_output
        self.httpd.job_log = self.job_log
        self.httpd.auth = SimpleNamespace(configured=True, session=lambda token: None)
        self.thread = Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def request(self, path, token=None, method="GET", extra_headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.httpd.server_port, timeout=3)
        headers = dict(extra_headers or {})
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        connection.request(method, path, headers=headers, body=b"{}" if method == "POST" else None)
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, json.loads(body)

    def duplicate_auth(self, token):
        connection = http.client.HTTPConnection("127.0.0.1", self.httpd.server_port, timeout=3)
        connection.putrequest("GET", "/api/v1/status")
        connection.putheader("Authorization", "Bearer " + token)
        connection.putheader("Authorization", "Bearer " + token)
        connection.endheaders()
        response = connection.getresponse()
        body = json.loads(response.read())
        connection.close()
        return response.status, body

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=3)


with tempfile.TemporaryDirectory() as temporary:
    fixture = ApiFixture(Path(temporary))
    try:
        status, payload = fixture.request("/api/v1/status", fixture.read_token)
        assert status == 200 and payload["api_version"] == 1
        assert payload["targets"][0]["name"] == "Windows <fixture>"
        assert payload["targets"][0]["windows_update"]["history"][0]["kb"] == "KB1234567"
        assert payload["targets"][0]["error"] is None
        assert payload["targets"][0]["skip_reason"] is None
        assert payload["targets"][1]["reachable"] is None
        assert payload["targets"][1]["error"] is None
        assert payload["targets"][1]["skip_reason"] == {
            "code": "STOPPED_READ_ONLY",
            "message": "LXC 100 is stopped; <fixture> remains escaped data",
        }

        # Error projection is bounded and uses generic public descriptions;
        # status-file diagnostics must never be exposed through the API.
        original_status = fixture.status.read_text(encoding="utf-8")
        error_payload = json.loads(original_status)
        error_payload["targets"].append({
            "id": "error-target", "type": "lxc", "check_status": "error",
            "error": {"code": "CHECK_COMMAND_FAILED",
                       "message": "password=secret command output " + ("x" * 5000)},
        })
        fixture.status.write_text(json.dumps(error_payload), encoding="utf-8")
        status, payload = fixture.request("/api/v1/status", fixture.read_token)
        assert status == 200
        error_target = next(item for item in payload["targets"] if item["id"] == "error-target")
        assert error_target["error"] == {
            "code": "CHECK_COMMAND_FAILED",
            "message": "The check command failed.",
        }
        assert error_target["skip_reason"] is None
        assert "password=secret" not in json.dumps(payload)
        assert len(error_target["error"]["message"]) < 256

        error_payload["targets"][-1]["error"] = {
            "code": "<PRIVATE_KEY>", "message": "Bearer token=do-not-leak",
        }
        fixture.status.write_text(json.dumps(error_payload), encoding="utf-8")
        status, payload = fixture.request("/api/v1/status", fixture.read_token)
        assert status == 200
        error_target = next(item for item in payload["targets"] if item["id"] == "error-target")
        assert error_target["error"] == {
            "code": "STATUS_ERROR",
            "message": "The target check failed.",
        }
        assert "Bearer token=do-not-leak" not in json.dumps(payload)
        fixture.status.write_text(original_status, encoding="utf-8")

        status, payload = fixture.request("/api/v1/status-summary", fixture.read_token)
        assert status == 200 and payload["summary"]["targets"] == 2
        assert payload["updates_available"] is None
        assert payload["summary"]["unknown_updates"] + payload["summary"]["unknown_reboot"] >= 1
        assert "986" not in json.dumps(payload)

        status, payload = fixture.request("/api/v1/jobs", fixture.read_token)
        assert status == 200 and len(payload["jobs"]) == 1
        assert fixture.httpd.command_calls[-1][0][1:] == ["list", "--cached"]
        status, payload = fixture.request("/api/v1/jobs/ultimate-updater-check-986-fixture", fixture.read_token)
        assert status == 200 and payload["job"]["exit_code"] == 0
        status, payload = fixture.request("/api/v1/jobs/not-a-unit", fixture.read_token)
        assert status == 400 and payload["error"]["code"] == "INVALID_JOB_ID"
        status, payload = fixture.request("/api/v1/jobs/ultimate-updater-update-missing", fixture.read_token)
        assert status == 404

        status, payload = fixture.request("/api/v1/jobs/ultimate-updater-check-986-fixture/log", fixture.read_token)
        assert status == 403 and payload["error"]["code"] == "API_PERMISSION_REQUIRED"
        status, payload = fixture.request("/api/v1/jobs/ultimate-updater-check-986-fixture/log", fixture.logs_token)
        assert status == 200 and payload["log"] == "safe fixture log\n"
        assert len(payload["log"]) <= 64 * 1024

        calls_before_version = len(fixture.httpd.command_calls)
        status, payload = fixture.request("/api/v1/updater-version", fixture.read_token)
        assert status == 200 and payload["installed"] == "5.2"
        assert len(fixture.httpd.command_calls) == calls_before_version

        for token in (None, "A" * 43, fixture.expired_token, fixture.revoked_token):
            status, _ = fixture.request("/api/v1/status", token)
            assert status == 401, status
        status, _ = fixture.duplicate_auth(fixture.read_token)
        assert status == 401
        status, _ = fixture.request("/api/v1/status", fixture.read_token, extra_headers={"Cookie": "UU_SESSION=browser"})
        assert status == 401
        status, _ = fixture.request("/api/v1/status", fixture.read_token, method="POST")
        assert status == 405
        status, _ = fixture.request("/api/status", fixture.read_token)
        assert status == 401
        status, _ = fixture.request("/api/update-all", fixture.read_token, method="POST",
                                    extra_headers={"Content-Type": "application/json"})
        assert status == 401

        fixture.httpd.tls_enabled = False
        status, payload = fixture.request("/api/v1/status", fixture.read_token)
        assert status == 503 and payload["error"]["code"] == "HTTPS_REQUIRED"
        fixture.httpd.tls_enabled = True

        fixture.status.write_text("{not json", encoding="utf-8")
        status, payload = fixture.request("/api/v1/status", fixture.read_token)
        assert status == 503 and payload["error"]["code"] == "API_DATA_UNAVAILABLE"
    finally:
        fixture.close()

print("API v1 HTTP handler tests: PASS")
