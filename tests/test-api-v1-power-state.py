#!/usr/bin/env python3
"""Regression coverage for the optional read-only API-v1 power-state view."""

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

SPEC = importlib.util.spec_from_file_location("ultimate_updater_web_api_v1_power_state", ROOT / "web-ui" / "server.py")
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)


class FixtureHandler(web.StatusHandler):
    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.server.command_calls.append(list(args))
        raise AssertionError(f"unexpected command: {args}")


def token_record(token):
    return {"id": "read", "name": "read-fixture", "hash": api_tokens.hash_token(token),
            "permissions": ["read"], "expires_at": None, "revoked": False}


def request(httpd, path, token):
    connection = http.client.HTTPConnection("127.0.0.1", httpd.server_port, timeout=3)
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    connection.request("GET", path, headers=headers)
    response = connection.getresponse()
    payload = json.loads(response.read())
    connection.close()
    return response.status, payload


def target_payload():
    stamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    return {
        "schema_version": 1,
        "generated_at": stamp,
        "targets": [
            {"id": "118", "type": "vm", "node": "node-a", "name": "vm118",
             "os": "Linux", "check_status": "ok", "reachable": True,
             "updates": {"available": 0}, "power_state": {"value": "running"}},
            {"id": "119", "type": "lxc", "node": "node-a", "name": "ct119",
             "os": "Debian", "check_status": "not_checked", "reachable": None,
             "updates": {"available": None}},
            {"id": "host:node-a", "type": "host", "node": "node-a", "name": "node-a",
             "os": "Proxmox", "check_status": "ok", "reachable": True,
             "updates": {"available": 0}},
            {"id": "remote-one", "type": "external", "node": None, "name": "remote-one",
             "check_status": "not_checked", "reachable": None,
             "updates": {"available": None},
             "power_state": {"value": "running", "source": "old-status"}},
        ],
    }


def resource(kind, node, status, vmid=None):
    item = {"type": kind, "node": node, "status": status}
    if vmid is not None:
        item["vmid"] = vmid
    return item


with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    status_file = root / "status.json"
    token_file = root / "api-tokens.json"
    token = secrets.token_urlsafe(32)
    status_file.write_text(json.dumps(target_payload()), encoding="utf-8")
    token_file.write_text(json.dumps({
        "version": 1, "enabled": True, "tokens": [token_record(token)],
    }), encoding="utf-8")
    token_file.chmod(0o600)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    httpd.status_file = status_file
    httpd.api_token_file = token_file
    httpd.status_api_token_file = token_file
    httpd.status_api_max_age_seconds = 86400
    httpd.package_freshness_max_age_seconds = 86400
    httpd.tls_enabled = True
    httpd.command_calls = []
    provider_calls = []
    live_resources = [
        resource("qemu", "node-a", "paused", 118),
        resource("lxc", "node-a", "stopped", 119),
        resource("node", "node-a", "online"),
    ]

    def provider():
        provider_calls.append(True)
        return live_resources

    httpd.proxmox_power_state_provider = provider
    original_status = status_file.read_bytes()
    thread = Thread(target=httpd.serve_forever, daemon=True)
    thread.start()

    try:
        # The default response is byte-for-byte scoped to the existing API
        # contract: no live provider is called and no new field is projected.
        status, payload = request(httpd, "/api/v1/status", token)
        assert status == 200
        assert provider_calls == []
        assert all("power_state" not in target for target in payload["targets"])

        status, payload = request(httpd, "/api/v1/status?include=power_state", token)
        assert status == 200
        assert len(provider_calls) == 1
        states = {target["id"]: target["power_state"] for target in payload["targets"]}
        assert states["118"]["value"] == "paused"
        assert states["119"]["value"] == "stopped"
        assert states["host:node-a"]["value"] == "online"
        assert states["remote-one"] is None
        assert all(states[target_id]["source"] == "proxmox"
                   for target_id in ("118", "119", "host:node-a"))
        observed = {states[target_id]["observed_at"]
                    for target_id in ("118", "119", "host:node-a")}
        assert len(observed) == 1
        assert states["remote-one"] is None
        assert all("old-status" not in json.dumps(target) for target in payload["targets"])
        assert httpd.command_calls == []

        # Invalid or ambiguous live results fail closed and never reuse the
        # persisted old value.
        live_resources[:] = [
            resource("qemu", "node-a", "running", 118),
            resource("qemu", "node-a", "stopped", 118),
            resource("lxc", "node-a", "unknown", 119),
            resource("node", "node-a", "online"),
        ]
        status, payload = request(httpd, "/api/v1/status?include=power_state", token)
        assert status == 200
        states = {target["id"]: target["power_state"] for target in payload["targets"]}
        assert states["118"] is None
        assert states["119"] is None
        assert states["remote-one"] is None
        assert len(provider_calls) == 2

        live_resources[:] = []
        status, payload = request(httpd, "/api/v1/status?include=power_state", token)
        assert status == 200
        assert all(target["power_state"] is None for target in payload["targets"])

        httpd.proxmox_power_state_provider = lambda: None
        status, payload = request(httpd, "/api/v1/status?include=power_state", token)
        assert status == 200
        assert all(target["power_state"] is None for target in payload["targets"])
        assert status_file.read_bytes() == original_status

        for query in ("include=power_state&include=power_state", "include=unknown"):
            status, payload = request(httpd, f"/api/v1/status?{query}", token)
            assert status == 400 and payload["error"]["code"] == "INVALID_STATUS_INCLUDE"
        status, payload = request(httpd, "/api/v1/status?include=power_state", "wrong-token")
        assert status == 401 and payload["error"]["code"] == "AUTH_REQUIRED"
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=3)


# The production helper itself must issue exactly one read-only cluster query.
calls = []


def fake_runner(args, **kwargs):
    calls.append((args, kwargs))
    return CompletedProcess(args, 0, json.dumps([resource("qemu", "node-a", "running", 118)]), "")


assert web.proxmox_power_state_snapshot(fake_runner) == [resource("qemu", "node-a", "running", 118)]
assert len(calls) == 1
assert calls[0][0] == ["pvesh", "get", "/cluster/resources", "--output-format", "json"]
assert calls[0][1]["timeout"] == 10

print("API v1 power-state tests: PASS")
