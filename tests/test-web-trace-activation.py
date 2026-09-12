#!/usr/bin/env python3
"""Verify that WebUI trace activation is explicit and per-job only."""

from pathlib import Path
from types import SimpleNamespace
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


class Handler:
    def __init__(self):
        self.server = SimpleNamespace(job_runner=Path("/runner"), cli=Path("/cli"))
        self.calls = []
        self.responses = []

    def run_command(self, args, timeout=15, extra_env=None):
        self.calls.append((args, timeout, extra_env))
        return SimpleNamespace(returncode=0, stdout="Job: ultimate-updater-check-all-systems-test\n", stderr="")

    def send_json(self, payload, status):
        self.responses.append((payload, status))


normal = Handler()
server.StatusHandler.action_check_all(normal)
assert normal.calls[0][2] is None

diagnostic = Handler()
server.StatusHandler.action_check_all(diagnostic, remote_trace=True)
assert diagnostic.calls[0][2] == {"UU_REMOTE_TRACE": "true"}

for value in (False, None, 1, "true", {"value": True}):
    handler = Handler()
    server.StatusHandler.action_check_all(handler, remote_trace=value)
    assert handler.calls[0][2] is None

source = (Path(__file__).parents[1] / "web-ui/server.py").read_text(encoding="utf-8")
assert 'payload.get("remote_trace") is True' in source
assert 'extra_env = {"UU_REMOTE_TRACE": "true"} if remote_trace is True else None' in source
assert "os.environ.update" not in source

print("web trace activation tests: PASS")
