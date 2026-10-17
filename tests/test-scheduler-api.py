#!/usr/bin/env python3
"""Exercise scheduler persistence and Run-now context through real HTTP handlers."""

import http.client
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


class AuthFixture:
    configured = True

    def session(self, token):
        if token == "test-session":
            return {"csrf": "test-csrf", "expires": 2**31}
        return None


class SchedulerHandler(server.StatusHandler):
    def jobs(self, reconcile=True):
        return []

    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.calls.append({"args": args, "timeout": timeout, "extra_env": extra_env or {}})
        if args and args[0] == str(self.server.cli):
            return SimpleNamespace(
                returncode=0,
                stdout="Check job started\nJob: ultimate-updater-check-all-systems-fixture\n",
                stderr="",
            )
        return SimpleNamespace(returncode=0, stdout="n/a\n", stderr="")


def request(httpd, method, path, payload=None):
    connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
    body = None if payload is None else json.dumps(payload)
    headers = {"Cookie": "UU_SESSION=test-session", "X-CSRF-Token": "test-csrf"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    data = json.loads(response.read())
    connection.close()
    return response.status, data


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    status = root / "status.json"
    status.write_text(json.dumps({"targets": []}), encoding="utf-8")
    schedule_file = root / "schedules.json"
    unit_dir = root / "units"
    cli = root / "ultimate-updater"
    cli.touch(mode=0o750)
    runner = root / "job-runner.sh"
    runner.touch(mode=0o750)

    httpd = server.ThreadingHTTPServer(("127.0.0.1", 0), SchedulerHandler)
    httpd.auth = AuthFixture()
    httpd.tls_enabled = False
    httpd.status_file = status
    httpd.scheduler_file = schedule_file
    httpd.scheduler_unit_dir = unit_dir
    httpd.cli = cli
    httpd.job_runner = runner
    httpd.jobs_dir = root / "jobs"
    httpd.calls = []
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        common = {"name": "Nightly", "type": "check-all", "days": ["Mon"], "time": "03:00", "enabled": True, "targets": []}
        status_code, payload = request(httpd, "POST", "/api/schedules", common)
        assert status_code == 201
        schedule = payload["schedule"]
        assert schedule["check_lifecycle_mode"] == "read_only"
        unit = unit_dir / f"ultimate-updater-schedule-{schedule['id']}.service"
        unit_text = unit.read_text(encoding="utf-8")
        assert "Environment=UU_JOB_SOURCE=initial-inventory" in unit_text
        assert "Environment=UU_SCHEDULED_CHECK=true" in unit_text
        assert "Environment=UU_NONINTERACTIVE=true" in unit_text

        status_code, run_payload = request(httpd, "POST", f"/api/schedules/{schedule['id']}/run", {})
        assert status_code == 202
        assert run_payload["state"] == "running"
        run_call = next(call for call in httpd.calls if call["args"][0] == str(cli))
        assert run_call["extra_env"] == server.scheduler_execution_env(schedule)

        normal_payload = {**common, "name": "Normal", "check_lifecycle_mode": "normal"}
        status_code, normal_response = request(httpd, "POST", "/api/schedules", normal_payload)
        assert status_code == 201
        normal = normal_response["schedule"]
        assert normal["check_lifecycle_mode"] == "normal"
        normal_unit = unit_dir / f"ultimate-updater-schedule-{normal['id']}.service"
        normal_text = normal_unit.read_text(encoding="utf-8")
        assert "Environment=UU_JOB_SOURCE=scheduler" in normal_text
        assert "Environment=UU_SCHEDULED_CHECK=true" in normal_text

        status_code, rejected = request(httpd, "POST", "/api/schedules", {**common, "check_lifecycle_mode": "unsafe"})
        assert status_code == 422
        assert rejected["error"]["code"] == "SCHEDULE_NOT_SAVED"
        assert len(json.loads(schedule_file.read_text(encoding="utf-8"))["schedules"]) == 2
    finally:
        httpd.shutdown()
        httpd.server_close()

print("scheduler API tests: PASS")
