#!/usr/bin/env python3
"""Verify safe, actionable WebUI update-start errors."""

from types import SimpleNamespace
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


def result(rc, stdout="", stderr=""):
    return SimpleNamespace(returncode=rc, stdout=stdout, stderr=stderr)


assert server.update_start_failure_message(
    result(6, stderr="Interactive job bridge is not available: /tmp/secret/path"), "generic"
) == "Interactive job setup failed."
assert server.update_start_failure_message(
    result(6, stderr="Could not prepare remote update workspace on node2"), "generic"
) == "The remote node is unavailable."
assert server.update_start_failure_message(
    result(124, stderr="timeout"), "generic"
) == "Job start timed out."
assert server.update_start_failure_message(result(9), "The update job could not be started.") == \
    "The update job could not be started. (exit code 9)."

print("web update-start error tests: PASS")
