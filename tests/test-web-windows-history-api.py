#!/usr/bin/env python3
"""Exercise the Windows-history POST handler with isolated HTTP fixtures."""

import http.client
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


JOB_OUTPUT = "Check job started\nTarget: 986\nJob: ultimate-updater-check-986-20261017-120000-123456789-1234567\n"


class AuthFixture:
    configured = True

    def session(self, token):
        if token == "test-session":
            return {"csrf": "test-csrf", "expires": 2**31}
        return None


class HistoryHandler(server.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.command_calls.append({
            "args": args,
            "timeout": timeout,
            "extra_env": extra_env or {},
        })
        return SimpleNamespace(returncode=0, stdout=JOB_OUTPUT, stderr="")


def make_server(directory, target, status_text=None):
    path = directory / "status.json"
    if status_text is None:
        path.write_text(json.dumps({"targets": [target]}), encoding="utf-8")
    else:
        path.write_text(status_text, encoding="utf-8")
    httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), HistoryHandler)
    httpd.auth = AuthFixture()
    httpd.tls_enabled = False
    httpd.status_file = path
    httpd.job_runner = directory / "mock-job-runner"
    httpd.cli = directory / "mock-cli"
    httpd.jobs_dir = directory / "jobs"
    httpd.jobs_dir.mkdir(exist_ok=True)
    httpd.windows_history_refresh_lock = threading.Lock()
    httpd.windows_history_refreshes = {}
    httpd.command_calls = []
    return httpd


def post(httpd, target="986"):
    connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
    connection.request(
        "POST",
        f"/api/windows-history/{target}/refresh",
        body="{}",
        headers={
            "Cookie": "UU_SESSION=test-session",
            "X-CSRF-Token": "test-csrf",
            "Content-Type": "application/json",
        },
    )
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def close_server(httpd):
    httpd.shutdown()
    httpd.server_close()


def valid_target(os_key, os_value):
    return {"id": "986", "type": "vm", os_key: os_value}


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)

    for os_key, os_value in (
        ("os", "Windows Server 2025"),
        ("os_detail_display", "Microsoft WINDOWS Server"),
        ("os", "wInDoWs 11"),
    ):
        httpd = make_server(root, valid_target(os_key, os_value))
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            status, payload = post(httpd)
            assert status == 202
            assert payload["type"] == "windows-history"
            assert payload["state"] == "running"
            assert payload["job"].startswith("ultimate-updater-check-986-")
            assert len(httpd.command_calls) == 1
            assert httpd.command_calls[0]["extra_env"]["UU_WINDOWS_HISTORY_ONLY"] == "true"
            assert httpd.command_calls[0]["extra_env"]["UU_JOB_INTERACTIVE"] == "true"
        finally:
            close_server(httpd)

    for target in ("not-a-vm", "987"):
        httpd = make_server(root, valid_target("os", "Windows Server 2025"))
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            status, payload = post(httpd, target)
            assert status == 400
            assert payload["error"]["code"] in {"INVALID_TARGET", "WINDOWS_TARGET_REQUIRED"}
            assert not httpd.command_calls
        finally:
            close_server(httpd)

    httpd = make_server(root, {"id": "986", "type": "vm", "os": "Debian 12"})
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        status, payload = post(httpd)
        assert status == 400
        assert payload["error"]["code"] == "WINDOWS_TARGET_REQUIRED"
        assert not httpd.command_calls
    finally:
        close_server(httpd)

    for status_text in (None, "not-json"):
        httpd = make_server(
            root,
            valid_target("os", "Windows Server 2025"),
            status_text=status_text if status_text is not None else None,
        )
        if status_text is None:
            httpd.status_file.unlink()
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            if status_text is None:
                status, payload = post(httpd)
            else:
                status, payload = post(httpd)
            assert status == 503
            assert payload["error"]["code"] == "STATUS_UNAVAILABLE"
            assert not httpd.command_calls
        finally:
            close_server(httpd)

    httpd = make_server(root, valid_target("os", "Windows Server 2025"))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        status, first = post(httpd)
        status, second = post(httpd)
        assert status == 202
        assert first["state"] == "running"
        assert second["state"] == "running"
        assert "already running" in second["message"]
        assert len(httpd.command_calls) == 1
    finally:
        close_server(httpd)

print("web Windows history API tests: PASS")
