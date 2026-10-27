#!/usr/bin/env python3
"""Verify safe, actionable WebUI update-start errors."""

from types import SimpleNamespace
from pathlib import Path
from http import HTTPStatus
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


def result(rc, stdout="", stderr=""):
    return SimpleNamespace(returncode=rc, stdout=stdout, stderr=stderr)


class Handler:
    def __init__(self, command_result=None, command_error=None):
        self.server = SimpleNamespace(
            cli=Path("/usr/bin/ultimate-updater"),
            job_runner=Path("/usr/bin/job-runner"),
        )
        self.command_result = command_result
        self.command_error = command_error
        self.calls = []
        self.responses = []

    def run_command(self, args, timeout=30, extra_env=None):
        self.calls.append((args, timeout, extra_env))
        if self.command_error:
            raise self.command_error
        return self.command_result

    def send_json(self, payload, status):
        self.responses.append((payload, status))


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
    result(41, stderr="Reason: no verified recent backup."),
    "The full check could not be started.",
    "check-all",
) == "The full check could not be started. (exit code 41)."

fixed_message = (
    "Full update blocked: selected External targets require a recent verified backup. "
    "Verify their backups or exclude them from this update."
)
raw_diagnostic = "Blocked external targets: external-name\nReason: no verified recent backup.\n/root/private"
update_all = Handler(result(41, stdout=raw_diagnostic))
server.StatusHandler.action_update_all(update_all)
payload, status = update_all.responses[0]
assert status == HTTPStatus.UNPROCESSABLE_ENTITY
assert payload == {"error": {"code": "UPDATE_START_FAILED", "message": fixed_message}}
assert update_all.calls[0][0] == ["/usr/bin/ultimate-updater", "update-all"]
assert "external-name" not in str(payload)
assert "/root/private" not in str(payload)

untrusted = Handler(result(41, stderr="Reason: no verified recent backup. /untrusted"))
server.StatusHandler.action_update_all(untrusted)
assert untrusted.responses[0] == (
    {"error": {"code": "UPDATE_START_FAILED", "message": "The full update job could not be started. (exit code 41)."}},
    HTTPStatus.UNPROCESSABLE_ENTITY,
)

check_all = Handler(result(41, stderr=raw_diagnostic))
server.StatusHandler.action_check_all(check_all)
assert check_all.responses[0] == (
    {"error": {"code": "CHECK_START_FAILED", "message": "The full check could not be started. (exit code 41)."}},
    HTTPStatus.UNPROCESSABLE_ENTITY,
)

other_failure = Handler(result(9, stderr=raw_diagnostic))
server.StatusHandler.action_update_all(other_failure)
assert other_failure.responses[0] == (
    {"error": {"code": "UPDATE_START_FAILED", "message": "The full update job could not be started. (exit code 9)."}},
    HTTPStatus.UNPROCESSABLE_ENTITY,
)

already_running = Handler(result(3))
server.StatusHandler.action_update_all(already_running)
assert already_running.responses[0] == (
    {"error": {"code": "JOB_ALREADY_RUNNING", "message": "A full update is already running."}},
    HTTPStatus.CONFLICT,
)

timed_out = Handler(command_error=subprocess.TimeoutExpired(["update-all"], 30))
server.StatusHandler.action_update_all(timed_out)
assert timed_out.responses[0] == (
    {"error": {"code": "UPDATE_START_FAILED", "message": "The full update job could not be started."}},
    HTTPStatus.BAD_GATEWAY,
)

print("web update-start error tests: PASS")
