#!/usr/bin/env python3
"""Regression coverage for the additive WebUI interactive-job bridge."""

import importlib.util
import socket
import tempfile
import threading
import time
from types import SimpleNamespace
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


def test_broker_replays_exact_bytes_with_sequences_and_wakes_waiter():
    with tempfile.TemporaryDirectory() as temporary:
        socket_path = Path(temporary) / "control.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        listener.listen(1)
        ready = threading.Event()
        release = threading.Event()
        overflow_sent = threading.Event()
        hold = threading.Event()

        def accept_client():
            client, _ = listener.accept()
            assert client.recv(64).startswith(b"\x00UU_RESIZE 24 80\n")
            ready.set()
            client.sendall(bytes([0x1b]) + b"[31mraw" + bytes([0xff, 0x00, 0x0a]))
            client.sendall(b"second chunk\n")
            release.wait(2)
            client.sendall(b"overflow payload")
            overflow_sent.set()
            hold.wait(2)
            client.close()

        threading.Thread(target=accept_client, daemon=True).start()
        broker = WEB.InteractiveJobBroker(Path(temporary))
        unit = "ultimate-updater-update-replay-1"
        broker.attach(unit, "session", socket_path)
        assert ready.is_set()
        snapshot = None
        for _ in range(200):
            snapshot = broker.output_since(unit, "session", 0)
            if snapshot["chunks"]:
                break
            time.sleep(0.01)
        assert snapshot["chunks"]
        assert b"".join(data for _, data in snapshot["chunks"]) == bytes([0x1b]) + b"[31mraw" + bytes([0xff, 0x00, 0x0a]) + b"second chunk\n"
        assert [seq for seq, _ in snapshot["chunks"]] == sorted(seq for seq, _ in snapshot["chunks"])
        first_seq = snapshot["chunks"][0][0]
        replay = broker.output_since(unit, "session", first_seq - 1)
        assert replay["chunks"] == snapshot["chunks"]

        broker.max_replay_bytes = 8
        waiter_result = []
        waiter = threading.Thread(
            target=lambda: waiter_result.append(broker.wait_for_output(unit, "session", snapshot["next_seq"], timeout=1)),
            daemon=True,
        )
        waiter.start()
        release.set()
        waiter.join(timeout=2)
        bounded = broker.output_since(unit, "session", 0)
        assert bounded["truncated"] is True
        assert sum(len(data) for _, data in bounded["chunks"]) <= 8
        assert waiter_result and waiter_result[0]["next_seq"] > snapshot["next_seq"]

        close_waiter_result = []
        close_waiter = threading.Thread(
            target=lambda: close_waiter_result.append(
                broker.wait_for_output(unit, "session", waiter_result[0]["next_seq"], timeout=2)
            ),
            daemon=True,
        )
        close_waiter.start()
        assert overflow_sent.wait(1)
        broker.detach(unit, "session")
        close_waiter.join(timeout=2)
        assert close_waiter_result and close_waiter_result[0]["closed"] is True
        assert not broker.attached(unit)
        hold.set()
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


def test_interactive_lookup_reads_requested_state_directly():
    with tempfile.TemporaryDirectory() as temporary:
        jobs_dir = Path(temporary)
        unit = "ultimate-updater-update-test-1"
        (jobs_dir / f"{unit}.state").write_text(
            "\n".join([
                "schema_version=1",
                f"unit={unit}",
                "target=1",
                "state=running",
                "started_at=2026-09-08T00:00:00Z",
                "finished_at=",
                "exit_code=",
                "type=update",
                "interactive=true",
            ]) + "\n",
            encoding="utf-8",
        )
        handler = WEB.StatusHandler.__new__(WEB.StatusHandler)
        handler.server = SimpleNamespace(jobs_dir=jobs_dir)
        handler.jobs = lambda: (_ for _ in ()).throw(AssertionError("global job list was queried"))
        record = handler.direct_job_record(unit)
        assert record["unit"] == unit
        assert record["state"] == "running"
        assert record["interactive"] is True


test_state_metadata_is_backward_compatible()
test_broker_forwards_input_and_releases_attachment()
test_broker_replays_exact_bytes_with_sequences_and_wakes_waiter()
test_webui_exposes_only_authenticated_input_actions()
test_interactive_lookup_reads_requested_state_directly()
print("web interactive UI tests: PASS")
