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

assert server.update_start_failure_message(
    result(41, stderr="Blocked external targets: oci-vps\nReason: no verified recent backup."),
    "The full update job could not be started.",
) == (
    "Full update blocked: selected External targets require a recent verified backup. "
    "Verify their backups or exclude them from this update."
)
assert server.update_start_failure_message(
    result(41, stderr="Untrusted diagnostic with a private path /root/token"),
    "The full update job could not be started.",
) == "The full update job could not be started. (exit code 41)."

assert "update_start_failure_message" in server.StatusHandler.action_update_all.__code__.co_names

print("web update-start error tests: PASS")
