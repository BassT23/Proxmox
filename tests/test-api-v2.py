#!/usr/bin/env python3
"""HTTP-handler regression coverage for the scoped API-2 actions.

All command execution is intercepted by the fixture handler.  No systemd,
Proxmox command, guest agent, package manager, or real job is started.
"""

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

SPEC = importlib.util.spec_from_file_location("ultimate_updater_web_api_v2", ROOT / "web-ui" / "server.py")
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


def token_record(token_id, token, permissions):
    return {"id": token_id, "name": token_id, "hash": api_tokens.hash_token(token),
            "permissions": permissions, "expires_at": None, "revoked": False}


class FixtureHandler(web.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        call = {"args": list(args), "timeout": timeout, "env": dict(extra_env or {})}
        self.server.calls.append(call)
        if args and args[0] == str(self.server.job_runner) and len(args) > 1 and args[1] == "list":
            return CompletedProcess(args, 0, self.server.jobs_output, "")
        if args and args[0] == str(self.server.job_runner) and len(args) > 1 and args[1] == "cancel":
            return CompletedProcess(args, 0, "Cancellation requested\n", "")
        if args and args[0] == str(self.server.job_runner) and len(args) > 1 and args[1] == "start-check":
            unit = "ultimate-updater-check-986-fixture"
            return CompletedProcess(args, self.server.next_returncode, f"Job: {unit}\n", "")
        if args and args[0] == str(self.server.cli) and len(args) > 1 and args[1] == "update":
            unit = "ultimate-updater-update-986-fixture"
            return CompletedProcess(args, self.server.next_returncode, f"Job: {unit}\n", "")
        if args and args[0] == str(self.server.cli) and len(args) > 1 and args[1] == "update-node":
            unit = "ultimate-updater-update-node-fixture"
            return CompletedProcess(args, self.server.next_returncode, f"Job: {unit}\n", "")
        if args and args[0] == str(self.server.job_runner) and len(args) > 1 and args[1] == "start-reboot":
            unit = "ultimate-updater-reboot-986-fixture"
            return CompletedProcess(args, self.server.next_returncode, f"Job: {unit}\n", "")
        return CompletedProcess(args, 1, "", "unsupported fixture command")

    def known_node(self, node):
        return node in {"test-node", "host:test-node"}

    def node_action_target(self, node):
        return "test-node"

    def reboot_target_record(self, target_id):
        return self.server.reboot_record if target_id == "986" else None

    def internal_ssh_catalog(self):
        return ([{"id": "test-node", "host": "127.0.0.1", "user": "root", "port": 22,
                   "identity_file": "", "enabled": True}], {})


class ApiFixture:
    def __init__(self, root):
        self.root = root
        self.status = root / "status.json"
        self.tokens = root / "api-tokens.json"
        self.runner = root / "job-runner.sh"
        self.cli = root / "ultimate-updater"
        self.config = root / "update.conf"
        self.status.write_text(json.dumps({
            "schema_version": 1,
            "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "targets": [
                {"id": "986", "type": "vm", "node": "test-node", "name": "Windows fixture",
                 "transport": "qga", "os": "Windows Server 2025", "reachable": True,
                 "check_status": "ok", "reboot_required": True, "updates": {"available": 1}},
                {"id": "100", "type": "lxc", "node": "test-node", "name": "Linux fixture",
                 "transport": "pct", "os": "Debian", "reachable": True,
                 "check_status": "ok", "reboot_required": False, "updates": {"available": 0}},
                {"id": "host:test-node", "type": "host", "node": "test-node", "name": "test-node",
                 "transport": "local", "os": "Proxmox", "reachable": True,
                 "check_status": "ok", "reboot_required": False, "updates": {"available": 0}},
            ],
        }), encoding="utf-8")
        self.runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.runner.chmod(0o750)
        self.cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.cli.chmod(0o750)
        self.config.write_text('USED_BRANCH="develop"\nEXTRA_GLOBAL="true"\n', encoding="utf-8")
        self.inventory = root / "targets.conf"
        self.inventory.write_text("", encoding="utf-8")
        self.cancel_unit = "ultimate-updater-check-986-cancel"
        (root / "jobs" / f"{self.cancel_unit}.state").parent.mkdir()
        (root / "jobs" / f"{self.cancel_unit}.state").write_text(
            f"unit={self.cancel_unit}\ntarget=986\nstate=running\nstarted_at=2026-10-17T10:00:00Z\n",
            encoding="utf-8",
        )
        self.tokens_data = {}
        for name, permissions in {
            "read": ["read"], "check": ["check"], "update": ["update"],
            "reboot": ["reboot"], "cancel": ["cancel"],
            "logs": ["read", "logs"], "all": ["read", "logs", "check", "update", "reboot", "cancel"],
        }.items():
            self.tokens_data[name] = secrets.token_urlsafe(32)
        self.tokens.write_text(json.dumps({
            "version": 1, "enabled": True,
            "tokens": [token_record(name, value, permissions)
                        for name, value in self.tokens_data.items()
                        for permissions in [{
                            "read": ["read"], "check": ["check"], "update": ["update"],
                            "reboot": ["reboot"], "cancel": ["cancel"],
                            "logs": ["read", "logs"], "all": ["read", "logs", "check", "update", "reboot", "cancel"],
                        }[name]]],
        }), encoding="utf-8")
        self.tokens.chmod(0o600)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        self.httpd.status_file = self.status
        self.httpd.api_token_file = self.tokens
        self.httpd.status_api_token_file = self.tokens
        self.httpd.status_api_max_age_seconds = 86400
        self.httpd.tls_enabled = True
        self.httpd.job_runner = self.runner
        self.httpd.cli = self.cli
        self.httpd.jobs_dir = root / "jobs"
        self.httpd.config_file = self.config
        self.httpd.inventory_file = self.inventory
        self.httpd.inventory_script = ROOT / "target-inventory.sh"
        self.httpd.api_local_node = "test-node"
        self.httpd.proxmox_inventory_provider = lambda: [
            {"type": "node", "node": "test-node", "status": "online"},
            {"type": "lxc", "vmid": 100, "node": "test-node", "name": "Linux fixture"},
            {"type": "qemu", "vmid": 986, "node": "test-node", "name": "Windows fixture"},
        ]
        self.httpd.backup_state_file = root / "backup.json"
        self.httpd.calls = []
        self.httpd.next_returncode = 0
        self.httpd.jobs_output = ""
        self.httpd.reboot_record = {
            "id": "986", "type": "vm", "node": "test-node", "reachable": True,
            "check_status": "ok", "reboot_required": True,
        }
        self.httpd.auth = SimpleNamespace(configured=True, session=lambda token: None)
        self.thread = Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def request(self, path, token=None, method="GET", body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.httpd.server_port, timeout=3)
        headers = {}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        encoded = None
        if body is not None:
            encoded = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        connection.request(method, path, body=encoded, headers=headers)
        response = connection.getresponse()
        payload = json.loads(response.read())
        connection.close()
        return response.status, payload

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=3)


with tempfile.TemporaryDirectory() as temporary:
    fixture = ApiFixture(Path(temporary))
    try:
        t = fixture.tokens_data

        status, payload = fixture.request("/api/v1/status", t["check"])
        assert status == 403 and payload["error"]["code"] == "API_PERMISSION_REQUIRED"
        status, payload = fixture.request("/api/v1/check/986", t["read"], method="POST")
        assert status == 403
        status, payload = fixture.request("/api/v1/check/986", None, method="POST")
        assert status == 401

        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 202 and payload["type"] == "check" and payload["job"].startswith("ultimate-updater-check-")
        assert fixture.httpd.calls[-1]["env"] == {
            "UU_API_ACTION": "check",
            "UU_JOB_SOURCE": "initial-inventory",
            "UU_NONINTERACTIVE": "true",
            "UU_API_EXPECTED_TARGET_ID": "986",
            "UU_API_EXPECTED_TARGET_KIND": "vm",
            "UU_API_EXPECTED_TARGET_NODE": "test-node",
            "UU_API_EXPECTED_TARGET_LOCAL": "true",
        }
        assert fixture.httpd.calls[-1]["args"][1:] == ["start-check", "986", str(fixture.cli), "target"]
        status, payload = fixture.request("/api/v1/check/guest%3A986", t["check"], method="POST")
        assert status == 202 and payload["target"] == "986"

        status, payload = fixture.request("/api/v1/check-all", t["check"], method="POST")
        assert status == 202 and payload["target"] == "all-systems"
        status, payload = fixture.request("/api/v1/check-node/test-node", t["check"], method="POST")
        assert status == 202 and payload["target"] == "test-node"
        before = len(fixture.httpd.calls)
        status, payload = fixture.request("/api/v1/check/host:test-node", t["check"], method="POST")
        assert status == 422 and payload["error"]["code"] == "USE_NODE_ACTION"
        assert len(fixture.httpd.calls) == before
        status, payload = fixture.request("/api/v1/check/999", t["check"], method="POST")
        assert status == 404 and payload["error"]["code"] == "TARGET_NOT_FOUND"
        status, payload = fixture.request("/api/v1/check/%40invalid", t["check"], method="POST")
        assert status == 400 and payload["error"]["code"] == "INVALID_TARGET"
        assert not any(call["args"][1:] == ["start-check", "999", str(fixture.cli), "target"]
                       for call in fixture.httpd.calls)

        status, payload = fixture.request("/api/v1/update/986", t["update"], method="POST")
        assert status == 422 and payload["error"]["code"] == "CONFIRMATION_REQUIRED"
        status, payload = fixture.request("/api/v1/update/986", t["update"], method="POST", body={"confirm": True})
        assert status == 202 and payload["type"] == "update"
        update_call = fixture.httpd.calls[-1]
        assert "--without-verified-backup" not in update_call["args"]
        assert update_call["env"] == {
            "UU_API_ACTION": "update",
            "UU_NONINTERACTIVE": "true",
            "UU_API_REBOOT_ALLOWED": "false",
            "UU_API_EXPECTED_TARGET_ID": "986",
            "UU_API_EXPECTED_TARGET_KIND": "vm",
            "UU_API_EXPECTED_TARGET_NODE": "test-node",
            "UU_API_EXPECTED_TARGET_LOCAL": "true",
        }
        status, payload = fixture.request("/api/v1/update-node/test-node", t["update"], method="POST", body={"confirm": True})
        assert status == 202 and payload["target"] == "test-node"

        # API script safety is checked before the job runner is invoked.  This
        # uses the real HTTP handler with an isolated target-local fixture.
        custom_scripts = fixture.root / "scripts.d" / "986"
        custom_scripts.mkdir(parents=True)
        (custom_scripts / "custom.sh").write_text("#!/bin/sh\n", encoding="utf-8")
        before = len(fixture.httpd.calls)
        status, payload = fixture.request("/api/v1/update/986", t["update"], method="POST", body={"confirm": True})
        assert status == 409 and payload["error"]["code"] == "API_UNSAFE_SCRIPT_PATH"
        assert len(fixture.httpd.calls) == before
        (custom_scripts / "custom.sh").unlink()
        (custom_scripts / ".script-only").write_text("\n", encoding="utf-8")
        status, payload = fixture.request("/api/v1/update/986", t["update"], method="POST", body={"confirm": True})
        assert status == 409 and payload["error"]["code"] == "API_UNSAFE_SCRIPT_PATH"
        assert len(fixture.httpd.calls) == before

        # API actions use current Proxmox identity, while status.json only
        # proves that the target is in the managed scope.  Each conflict is
        # exercised through the actual HTTP handler and must not start a job.
        original_status = json.loads(fixture.status.read_text(encoding="utf-8"))
        original_provider = fixture.httpd.proxmox_inventory_provider
        fixture.status.write_text(json.dumps({**original_status, "targets": original_status["targets"] + [
            {"id": "900", "type": "external", "node": None, "transport": "ssh"},
        ]}), encoding="utf-8")
        fixture.httpd.proxmox_inventory_provider = lambda: [
            {"type": "node", "node": "test-node", "status": "online"},
            {"type": "lxc", "vmid": 900, "node": "test-node", "name": "current-lxc"},
            {"type": "qemu", "vmid": 986, "node": "test-node", "name": "Windows fixture"},
        ]
        before = len(fixture.httpd.calls)
        status, payload = fixture.request("/api/v1/check/900", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before

        fixture.status.write_text(json.dumps({**original_status, "targets": original_status["targets"] + [
            {"id": "901", "type": "vm", "node": "test-node", "transport": "qga"},
        ]}), encoding="utf-8")
        fixture.httpd.proxmox_inventory_provider = lambda: [
            {"type": "node", "node": "test-node", "status": "online"},
            {"type": "lxc", "vmid": 901, "node": "test-node", "name": "reused-id"},
            {"type": "qemu", "vmid": 986, "node": "test-node", "name": "Windows fixture"},
        ]
        status, payload = fixture.request("/api/v1/check/901", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before

        fixture.status.write_text(json.dumps(original_status), encoding="utf-8")
        fixture.httpd.proxmox_inventory_provider = lambda: [
            {"type": "node", "node": "test-node", "status": "online"},
            {"type": "lxc", "vmid": 100, "node": "test-node", "name": "Linux fixture"},
            {"type": "qemu", "vmid": 986, "node": "other-node", "name": "migrated fixture"},
        ]
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before

        fixture.httpd.proxmox_inventory_provider = original_provider
        fixture.status.write_text(json.dumps({**original_status, "targets": [
            {**item, "type": "lxc"} if item["id"] == "986" else item
            for item in original_status["targets"]
        ]}), encoding="utf-8")
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before

        fixture.httpd.proxmox_inventory_provider = lambda: [
            {"type": "node", "node": "test-node", "status": "online"},
            {"type": "qemu", "vmid": 986, "node": "test-node", "name": "Windows fixture"},
            {"type": "qemu", "vmid": 986, "node": "test-node", "name": "duplicate"},
        ]
        status, payload = fixture.request("/api/v1/update/986", t["update"], method="POST", body={"confirm": True})
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_AMBIGUOUS"
        assert len(fixture.httpd.calls) == before

        fixture.httpd.proxmox_inventory_provider = lambda: None
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 503 and payload["error"]["code"] == "API_TARGET_INVENTORY_UNAVAILABLE"
        assert len(fixture.httpd.calls) == before

        fixture.httpd.proxmox_inventory_provider = original_provider
        fixture.status.write_text(json.dumps({**original_status, "targets": [
            item for item in original_status["targets"] if item["id"] != "986"
        ]}), encoding="utf-8")
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 404 and payload["error"]["code"] == "TARGET_NOT_FOUND"
        assert len(fixture.httpd.calls) == before

        fixture.status.write_text(json.dumps({**original_status, "targets": [
            {**item, "node": "other-node"} if item["id"] in {"986", "host:test-node"} else item
            for item in original_status["targets"]
        ]}), encoding="utf-8")
        status, payload = fixture.request("/api/v1/reboot/986", t["reboot"], method="POST", body={"confirm": True})
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before
        status, payload = fixture.request("/api/v1/check-node/test-node", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before
        status, payload = fixture.request("/api/v1/update-node/test-node", t["update"], method="POST", body={"confirm": True})
        assert status == 409 and payload["error"]["code"] == "API_TARGET_IDENTITY_MISMATCH"
        assert len(fixture.httpd.calls) == before
        fixture.status.write_text(json.dumps(original_status), encoding="utf-8")

        status, payload = fixture.request("/api/v1/reboot/986", t["update"], method="POST", body={"confirm": True})
        assert status == 403
        status, payload = fixture.request("/api/v1/reboot/986", t["reboot"], method="POST")
        assert status == 422 and payload["error"]["code"] == "CONFIRMATION_REQUIRED"
        status, payload = fixture.request("/api/v1/reboot/986", t["reboot"], method="POST", body={"confirm": True})
        assert status == 202 and payload["type"] == "reboot" and payload["api_version"] == 1

        status, payload = fixture.request(f"/api/v1/jobs/{fixture.cancel_unit}/cancel", t["cancel"], method="POST")
        assert status == 202 and payload["state"] == "stopping"
        status, payload = fixture.request("/api/v1/update-all", t["all"], method="POST", body={"confirm": True})
        assert status == 405

        before = len(fixture.httpd.calls)
        fixture.httpd.next_returncode = 3
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 409 and payload["error"]["code"] == "JOB_CONFLICT"
        assert len(fixture.httpd.calls) == before + 1
        fixture.httpd.next_returncode = 0

        fixture.httpd.tls_enabled = False
        before = len(fixture.httpd.calls)
        status, payload = fixture.request("/api/v1/check/986", t["check"], method="POST")
        assert status == 503 and payload["error"]["code"] == "HTTPS_REQUIRED"
        assert len(fixture.httpd.calls) == before
        fixture.httpd.tls_enabled = True

        status, _ = fixture.request("/api/config", t["all"])
        assert status == 401
    finally:
        fixture.close()

print("API v2 HTTP action tests: PASS")
