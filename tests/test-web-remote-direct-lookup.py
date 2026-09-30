#!/usr/bin/env python3
"""Verify targeted remote job lookup without a local state file."""

from pathlib import Path
from types import SimpleNamespace
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


UNIT = "ultimate-updater-update-920-fixture"
REMOTE_ROW = "\t".join((UNIT, "920", "running", "2026-09-13T10:00:00Z", "", "", "update", "node2", "fixture", "true", "true"))


class Handler:
    def __init__(self, output="", returncode=0):
        self.server = SimpleNamespace(jobs_dir=Path(tempfile.mkdtemp()), job_runner=Path("/runner"))
        self.output = output
        self.returncode = returncode
        self.calls = []

    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        self.calls.append((args, timeout))
        return SimpleNamespace(returncode=self.returncode, stdout=self.output, stderr="")


handler = Handler(REMOTE_ROW + "\n")
job = server.StatusHandler.direct_job_record(handler, UNIT)
assert job["remote"] is True
assert job["owner_node"] == "node2"
assert job["state"] == "running"
assert job["interactive"] is True
assert job["socket_available"] is True
assert handler.calls == [(["/runner", "show", UNIT], 10)]

missing = Handler(REMOTE_ROW + "\n")
assert server.StatusHandler.direct_job_record(missing, "ultimate-updater-update-921-fixture") is None
assert missing.calls == [(["/runner", "show", "ultimate-updater-update-921-fixture"], 10)], missing.calls

print("web remote direct lookup tests: PASS")
