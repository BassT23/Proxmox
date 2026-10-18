#!/usr/bin/env python3
"""Regression coverage for additive API-v1 integration metadata."""

from datetime import datetime, timezone
import http.client
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import tempfile
from http.server import ThreadingHTTPServer
from subprocess import CompletedProcess
from threading import Thread
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import api_tokens  # noqa: E402

SPEC = importlib.util.spec_from_file_location("ultimate_updater_web_api_v1_metadata", ROOT / "web-ui" / "server.py")
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


def token_record(token):
    return {"id": "read", "name": "read-fixture", "hash": api_tokens.hash_token(token),
            "permissions": ["read"], "expires_at": None, "revoked": False}


class FixtureHandler(web.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.calls.append(list(args))
        if args == [str(self.server.job_runner), "list", "--cached"]:
            return CompletedProcess(args, 0, self.server.jobs_output, "")
        return CompletedProcess(args, 1, "", "unexpected command")


def job_line(unit, target, number):
    stamp = f"2026-01-{number:02d}T00:00:00Z"
    return f"{unit}\t{target}\tcompleted\t{stamp}\t{stamp}\t0\tcheck\t\tfalse\tfalse\n"


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    status_file = root / "status.json"
    token_file = root / "api-tokens.json"
    config_file = root / "update.conf"
    job_runner = root / "job-runner.sh"
    token = secrets.token_urlsafe(32)

    status_file.write_text(json.dumps({
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "targets": [
            {"id": "118", "type": "lxc", "node": "node1", "name": "debian",
             "os": "Debian GNU/Linux 13 (trixie)", "check_status": "ok", "reachable": True,
             "updates": {"available": 0}},
            {"id": "119", "type": "vm", "node": "node1", "name": "ubuntu",
             "os": "Ubuntu", "os_version": "24.04", "check_status": "ok", "reachable": True,
             "updates": {"available": 0}},
            {"id": "host:node1", "type": "host", "node": "node1", "name": "node1",
             "os": "Proxmox", "check_status": "ok", "reachable": True,
             "updates": {"available": 0}},
            {"id": "external-one", "type": "external", "node": None, "name": "external-one",
             "check_status": "not_checked", "reachable": None, "updates": {"available": None}},
        ],
    }), encoding="utf-8")
    token_file.write_text(json.dumps({
        "version": 1, "enabled": True, "tokens": [token_record(token)],
    }), encoding="utf-8")
    token_file.chmod(0o600)
    config_file.write_text(
        'CHECK_STOPPED_CONTAINER="true"\n'
        'CHECK_STOPPED_VM="false"\n'
        'CHECK_PAUSED_VM="maybe"\n'
        'STOPPED_CONTAINER="false"\n'
        'STOPPED_VM="true"\n',
        encoding="utf-8",
    )
    job_runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    job_runner.chmod(0o750)

    jobs = [job_line("ultimate-updater-check-118-old", "118", 1)]
    jobs.extend(job_line(
        "ultimate-updater-check-node1" if target == "host:node1" else f"ultimate-updater-check-{target}",
        target, index,
    )
                for index, target in enumerate(("119", "host:node1", *map(str, range(200, 220))), start=2))
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    httpd.status_file = status_file
    httpd.api_token_file = token_file
    httpd.status_api_token_file = token_file
    httpd.status_api_max_age_seconds = 86400
    httpd.package_freshness_max_age_seconds = 86400
    httpd.tls_enabled = True
    httpd.public_origin = None
    httpd.trusted_proxy_networks = ()
    httpd.job_runner = job_runner
    httpd.jobs_dir = root / "jobs"
    httpd.jobs_dir.mkdir()
    httpd.interactive_broker = SimpleNamespace(attached=lambda unit: False)
    httpd.config_file = config_file
    httpd.calls = []
    httpd.jobs_output = "".join(jobs)
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()

    def request(path, supplied_token=token):
        connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
        headers = {"Authorization": f"Bearer {supplied_token}"} if supplied_token else {}
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        return response.status, payload

    try:
        status, payload = request("/api/v1/status")
        assert status == 200
        assert payload["targets"][0]["os_display"] == "Debian 13"
        assert payload["targets"][1]["os_display"] == "Ubuntu 24.04"
        assert payload["targets"][3]["os_display"] == "Unknown"
        assert payload["targets"][0]["os"] == "Debian GNU/Linux 13 (trixie)"

        status, payload = request("/api/v1/jobs")
        assert status == 200 and len(payload["jobs"]) == web.VISIBLE_JOB_LIMIT
        assert not any(item["target"] == "118" for item in payload["jobs"])

        for target, expected in (("118", "118"), ("guest:119", "119"),
                                 ("host:node1", "host:node1")):
            status, payload = request(f"/api/v1/jobs?target={target}")
            assert status == 200 and [item["target"] for item in payload["jobs"]] == [expected], (target, status, payload)
        status, payload = request("/api/v1/jobs?target=not-managed")
        assert status == 404 and payload["error"]["code"] == "TARGET_NOT_FOUND"
        for query in ("target=118&target=119", "target=bad%20target"):
            status, payload = request(f"/api/v1/jobs?{query}")
            assert status == 400 and payload["error"]["code"] == "INVALID_TARGET_FILTER"

        calls_before_capabilities = len(httpd.calls)
        status, payload = request("/api/v1/capabilities")
        assert status == 200 and payload["api_version"] == 1 and payload["schema_version"] == 1
        capabilities = payload["capabilities"]
        assert capabilities["stopped_container"]["check"] == {
            "configured": True, "normal_behavior": "lifecycle_check",
            "initial_inventory_behavior": "read_only_skip",
        }
        assert capabilities["stopped_container"]["update"] == {
            "configured": False, "behavior": "skipped",
        }
        assert capabilities["stopped_vm"]["check"]["normal_behavior"] == "skipped"
        assert capabilities["stopped_vm"]["update"]["behavior"] == "lifecycle_update"
        assert capabilities["paused_vm"]["check"] == {
            "configured": None, "normal_behavior": "unknown",
            "initial_inventory_behavior": "read_only_skip",
        }
        assert len(httpd.calls) == calls_before_capabilities

        status, payload = request("/api/v1/capabilities", supplied_token="wrong-token")
        assert status == 401 and payload["error"]["code"] == "AUTH_REQUIRED"
        status, payload = request("/api/v1/capabilities", supplied_token=None)
        assert status == 401 and payload["error"]["code"] == "AUTH_REQUIRED"
    finally:
        httpd.shutdown()
        thread.join(timeout=3)
        httpd.server_close()

print("API v1 metadata tests: PASS")
