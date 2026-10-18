#!/usr/bin/env python3
"""Regression coverage for additive API-v1 package version details."""

from datetime import datetime, timedelta, timezone
import importlib.util
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "ultimate_updater_web_api_v1_package_details", ROOT / "web-ui" / "server.py"
)
web = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web)

NOW = datetime.now(timezone.utc).replace(microsecond=0)
STAMP = (NOW - timedelta(seconds=1)).isoformat().replace("+00:00", "Z")


def target(available, packages, **overrides):
    value = {
        "id": "118",
        "type": "lxc",
        "node": "node1",
        "reachable": True,
        "check_status": "updates_available" if available else "ok",
        "package_checked_at": STAMP,
        "package_data_invalidated": False,
        "package_mutation_generation": 0,
        "package_mutation_in_progress": False,
        "updates": {"available": available},
        "packages": packages,
    }
    value.update(overrides)
    return value


def project(value):
    return web.StatusHandler._api_v1_target(value, now=NOW)["packages"]


details = [{
    "name": "openssl",
    "old_version": "3.0.11-1",
    "new_version": "3.0.11-1+deb12u5",
}]
assert project(target(1, details)) == details
assert project(target(0, [])) == []
assert project(target(1, None)) is None
assert project(target(1, details, package_checked_at="2020-01-01T00:00:00Z")) is None
assert project(target(1, details, check_status="error", error={"code": "CHECK_COMMAND_FAILED"})) is None
assert project(target(1, details, check_status="unsupported")) is None
assert project(target(1, [])) is None
assert project(target(1, [{"name": "openssl", "old_version": "old", "new_version": "new"},
                         {"name": "curl", "old_version": "old", "new_version": "new"}])) is None
assert project(target(1, [{"name": "openssl", "old_version": "old", "new_version": 5}])) is None
assert project({"id": "legacy", "check_status": "ok", "updates": {"available": 1}}) is None


# APT is the first backend with reliable installed/candidate version data.
with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    (fixture / "apt.py").write_text(
        """class Origin:
    origin = 'Debian'
    archive = 'stable-security'
    codename = 'bookworm'
    label = 'Debian'
    site = 'deb.debian.org'
    component = 'main'

class Version:
    def __init__(self, value):
        self.version = value
    @property
    def origins(self):
        return [Origin()]

class Package:
    name = 'openssl'
    is_upgradable = True
    installed = Version('3.0.11-1')
    candidate = Version('3.0.11-1+deb12u5')

class Cache:
    def __iter__(self):
        return iter([Package()])
""",
        encoding="utf-8",
    )
    helper = subprocess.run(
        [sys.executable, str(ROOT / "apt-count.py")],
        cwd=ROOT,
        env={**os.environ, "PYTHONPATH": str(fixture), "UU_PACKAGE_DETAILS": "1"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert helper.returncode == 0, helper.stderr
    fields = helper.stdout.strip().split("|")
    assert fields[:5] == ["APT_COUNTS", "1", "0", "1", "true"]
    assert json.loads(base64.b64decode(fields[5]).decode("utf-8")) == details


with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    (fixture / "apt.py").write_text(
        """class Origin:
    archive = 'stable-security'

class Version:
    def __init__(self, value):
        self.version = value
    @property
    def origins(self):
        return [Origin()]

class Package:
    is_upgradable = True
    def __init__(self, name, old_version, new_version):
        self.name = name
        self.installed = Version(old_version)
        self.candidate = Version(new_version)

class Cache:
    def __iter__(self):
        return iter([
            Package('zulu', '1', '2'),
            Package('alpha', '3', '4'),
        ])
""",
        encoding="utf-8",
    )
    helper = subprocess.run(
        [sys.executable, str(ROOT / "apt-count.py")],
        cwd=ROOT,
        env={**os.environ, "PYTHONPATH": str(fixture), "UU_PACKAGE_DETAILS": "1"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert helper.returncode == 0, helper.stderr
    fields = helper.stdout.strip().split("|")
    assert fields[:5] == ["APT_COUNTS", "2", "0", "2", "true"]
    assert json.loads(base64.b64decode(fields[5]).decode("utf-8")) == [
        {"name": "alpha", "old_version": "3", "new_version": "4"},
        {"name": "zulu", "old_version": "1", "new_version": "2"},
    ]


with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    (fixture / "apt.py").write_text(
        """class Origin:
    archive = 'stable-security'

class Version:
    def __init__(self, value):
        self.version = value
    @property
    def origins(self):
        return [Origin()]

class Package:
    name = 'openssl'
    is_upgradable = True
    installed = None
    candidate = Version('3.0.11-1+deb12u5')

class Cache:
    def __iter__(self):
        return iter([Package()])
""",
        encoding="utf-8",
    )
    helper = subprocess.run(
        [sys.executable, str(ROOT / "apt-count.py")],
        cwd=ROOT,
        env={**os.environ, "PYTHONPATH": str(fixture), "UU_PACKAGE_DETAILS": "1"},
        check=False,
        capture_output=True,
        text=True,
    )
    assert helper.returncode == 0, helper.stderr
    fields = helper.stdout.strip().split("|")
    assert fields == ["APT_COUNTS", "1", "0", "1", "true"]


# The status writer carries the normalized list in the existing optional
# metadata object; no positional record layout or schema version is changed.
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    status_file = root / "status.json"
    records = root / "status.records"
    model = ROOT / "status-model.sh"
    command = [
        "bash", "-c",
        "source \"$1\"; STATUS_MODEL_RECORD \"118\" lxc pct true Debian apt 1 false updates_available '' '' node1 lxc-118 null null '' now '' '' '' '' \"$2\"; STATUS_MODEL_FINISH",
        "status-model-test", str(model), json.dumps(details, separators=(",", ":")),
    ]
    result = subprocess.run(
        command,
        cwd=ROOT,
        env={
            **os.environ,
            "STATUS_MODEL_FILE": str(status_file),
            "STATUS_MODEL_RECORD_FILE": str(records),
            "STATUS_MODEL_CHECK_GENERATION": "0",
            "STATUS_MODEL_CHECK_STARTED_DURING_MUTATION": "false",
        },
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    persisted = json.loads(status_file.read_text(encoding="utf-8"))
    assert persisted["schema_version"] == 1
    assert persisted["targets"][0]["packages"] == details

    remote_file = root / "remote-status.json"
    remote_file.write_text(json.dumps({
        "schema_version": 1,
        "generated_at": STAMP,
        "targets": [{
            "id": "external-one", "type": "external", "transport": "ssh",
            "reachable": True, "os": "Debian", "updater": "apt",
            "updates": {"available": 1}, "reboot_required": False,
            "check_status": "updates_available", "last_check": STAMP,
            "package_checked_at": STAMP, "package_data_invalidated": False,
            "package_mutation_generation": 0, "package_mutation_in_progress": False,
            "packages": details,
        }],
    }), encoding="utf-8")
    imported_status = root / "imported.json"
    imported_records = root / "imported.records"
    imported = subprocess.run(
        [
            "bash", "-c",
            "source \"$1\"; STATUS_MODEL_INIT; STATUS_MODEL_IMPORT_FILE \"$2\"; STATUS_MODEL_FINISH",
            "status-import-test", str(model), str(remote_file),
        ],
        cwd=ROOT,
        env={
            **os.environ,
            "STATUS_MODEL_FILE": str(imported_status),
            "STATUS_MODEL_RECORD_FILE": str(imported_records),
        },
        check=False,
        capture_output=True,
        text=True,
    )
    assert imported.returncode == 0, imported.stderr
    imported_payload = json.loads(imported_status.read_text(encoding="utf-8"))
    assert imported_payload["targets"][0]["packages"] == details

print("API v1 package detail tests: PASS")
