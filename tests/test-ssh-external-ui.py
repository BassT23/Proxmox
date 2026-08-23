#!/usr/bin/env python3
"""Regression checks for read-only SSH connection-test routing and UI feedback."""

import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import sys
sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


source = Path(__file__).parents[1].joinpath("web-ui/server.py").read_text(encoding="utf-8")
assert "cluster-target.sh" in source
assert "Testing connection…" in server.PAGE
assert "Connection failed:" in server.PAGE
assert "testTarget(payload.id,payload)" in server.PAGE
assert "uname -s" in server.StatusHandler.handle_target_test.__code__.co_consts
assert "owner_node_for_guest" in server.StatusHandler.run_owner_guest_connection_test.__code__.co_names

with tempfile.NamedTemporaryFile() as identity:
    payload = server.validate_target_payload({
        "id": "mediacenter", "host": "192.168.40.73", "user": "basst",
        "port": 22, "identity_file": identity.name,
    })
    assert payload["identity_file"] == identity.name
    command = server.StatusHandler.ssh_command(payload, "uname -s")
    assert command[-1] == "uname -s"
    assert "-i" in command and identity.name in command

fake_result = SimpleNamespace(returncode=0, stdout="Linux\n", stderr="")
with patch("server.subprocess.run", return_value=fake_result) as run:
    result, message = server.StatusHandler.run_ssh_connection_test(
        object.__new__(server.StatusHandler), payload, "uname -s"
    )
assert message is None and result.stdout.strip() == "Linux"
assert run.call_args.args[0][-1] == "uname -s"

assert server.ssh_failure_message("ssh: connect to host x port 22: Connection refused") == "Connection refused."
assert server.ssh_failure_message("Permission denied (publickey)") == "Authentication failed."
assert server.ssh_failure_message("") == "Connection failed."

owner = object.__new__(server.StatusHandler)
owner.server = SimpleNamespace(cluster_target_script=Path(__file__))
owner.run_command = lambda _args, timeout=15: fake_result.__class__(
    returncode=0, stdout="310\tvm\tnode3\toctoprint\t192.168.10.103\tfalse\n", stderr=""
)
owner.internal_ssh_catalog = lambda: ([{
    "kind": "node", "id": "node3", "host": "192.168.10.103", "user": "root",
    "port": 22, "identity_file": "", "enabled": True,
}], [])
guest = {"id": "310", "host": "192.168.40.310", "user": "root", "port": 22,
         "identity_file": ""}
with patch("server.subprocess.run", return_value=fake_result) as run:
    result, message = owner.run_owner_guest_connection_test(guest)
assert message is None and result.returncode == 0
outer_command = run.call_args.args[0]
assert "root@192.168.10.103" in outer_command
assert "root@192.168.40.310" in outer_command[-1]

inventory = "[mediacenter]\nhost=192.168.40.73\ntransport=ssh\nuser=basst\nport=22\n"
updated = server.update_inventory_text(inventory, payload)
assert f"identity_file={identity.name}" in updated
cleared = server.update_inventory_text(updated, {**payload, "identity_file": ""}, "mediacenter")
assert "identity_file=" not in cleared

print("SSH/external UI regression checks passed.")
