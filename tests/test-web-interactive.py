#!/usr/bin/env python3
"""Regression coverage for the additive WebUI interactive-job bridge."""

import importlib.util
import socket
import tempfile
import threading
import time
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_web", ROOT / "web-ui" / "server.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


def test_state_metadata_is_backward_compatible():
    old = WEB.parse_state_line("unit\ttarget\trunning\tstart\t\t\tupdate\t\tsource")
    assert old["interactive"] is False
    assert old["socket_available"] is False
    new = WEB.parse_state_line("unit\ttarget\trunning\tstart\t\t\tupdate\t\tsource\ttrue\ttrue")
    assert new["interactive"] is True
    assert new["socket_available"] is True


def test_broker_forwards_input_and_releases_attachment():
    with tempfile.TemporaryDirectory() as temporary:
        socket_path = Path(temporary) / "control.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        listener.listen(1)
        received = []
        release = threading.Event()

        def accept_client():
            client, _ = listener.accept()
            assert client.recv(64).startswith(b"\x00UU_RESIZE 24 80\n")
            client.sendall(b"prompt\n")
            received.append(client.recv(32))
            release.wait(1)
            client.close()

        threading.Thread(target=accept_client, daemon=True).start()
        broker = WEB.InteractiveJobBroker(Path(temporary))
        unit = "ultimate-updater-update-test-1"
        broker.attach(unit, "session", socket_path)
        broker.send(unit, "session", b"Y\n")
        for _ in range(200):
            if received:
                break
            time.sleep(0.01)
        assert received == [b"Y\n"]
        assert broker.detach(unit, "session") is True
        assert broker.attached(unit) is False
        release.set()
        listener.close()


def test_webui_exposes_only_authenticated_input_actions():
    source = (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert 'parts[3] == "attach"' in source
    assert 'parts[3] == "input"' in source
    assert 'parts[3] == "detach"' in source
    assert "self.write_allowed()" in source
    assert "The interactive job socket is unavailable." in source
    assert "Interactive input available" in WEB.PAGE
    assert "/api/jobs/${encodeURIComponent(unit)}/input" in WEB.PAGE
    assert "X-CSRF-Token" in WEB.PAGE
    assert "new MutationObserver(()=>decorateInteractiveJobs())" not in WEB.PAGE


test_state_metadata_is_backward_compatible()
test_broker_forwards_input_and_releases_attachment()
test_webui_exposes_only_authenticated_input_actions()
print("web interactive UI tests: PASS")
