#!/usr/bin/env python3
"""Regression coverage for the additive WebUI interactive-job bridge."""

import importlib.util
import base64
import http.client
import json
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


def test_broker_resize_uses_existing_attachment_socket_and_validates():
    with tempfile.TemporaryDirectory() as temporary:
        socket_path = Path(temporary) / "control.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        listener.listen(1)
        received = []

        def accept_client():
            client, _ = listener.accept()
            buffer = b""
            while buffer.count(b"\n") < 2:
                buffer += client.recv(64)
            received.extend(buffer.splitlines(keepends=True))
            client.close()

        threading.Thread(target=accept_client, daemon=True).start()
        broker = WEB.InteractiveJobBroker(Path(temporary))
        unit = "ultimate-updater-update-resize-1"
        broker.attach(unit, "session", socket_path)
        attachment_id = broker.clients[unit]["attachment_id"]
        broker.resize(unit, "session", attachment_id, 34, 118)
        for _ in range(200):
            if len(received) >= 2:
                break
            time.sleep(0.01)
        assert received[0].startswith(b"\x00UU_RESIZE 24 80\n")
        assert received[1] == b"\x00UU_RESIZE 34 118\n"
        for rows, cols in [(1, 80), (501, 80), (24, 1), (24, 501), ("24", 80)]:
            try:
                broker.resize(unit, "session", attachment_id, rows, cols)
            except ValueError:
                pass
            else:
                raise AssertionError("invalid terminal size was accepted")
        broker.detach(unit, "session", attachment_id)
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


def test_attachment_lifecycle_and_stream_grace():
    with tempfile.TemporaryDirectory() as temporary:
        socket_path = Path(temporary) / "control.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        listener.listen(1)
        hold = threading.Event()

        def accept_client():
            client, _ = listener.accept()
            client.recv(64)
            client.sendall(b"stream-test\n")
            hold.wait(2)
            client.close()

        threading.Thread(target=accept_client, daemon=True).start()
        broker = WEB.InteractiveJobBroker(Path(temporary))
        broker.STREAM_GRACE_SECONDS = 0.05
        unit = "ultimate-updater-update-attachment-1"
        attachment_id = broker.attach(unit, "session", socket_path)
        assert broker.valid_attachment_id(attachment_id)
        assert broker.stream_claim(unit, "session", attachment_id)
        stream_id = broker.clients[unit]["stream_id"]
        assert broker.stream_current(unit, "session", attachment_id, stream_id)
        try:
            broker.send(unit, "session", b"x", "wrong-attachment")
        except RuntimeError:
            pass
        else:
            raise AssertionError("wrong attachment was accepted")
        broker.stream_release(unit, "session", attachment_id, stream_id)
        assert broker.attached(unit)
        replacement_stream = broker.stream_claim(unit, "session", attachment_id)
        assert replacement_stream != stream_id
        broker.stream_release(unit, "session", attachment_id, replacement_stream)
        time.sleep(0.15)
        assert not broker.attached(unit)
        hold.set()
        listener.close()


def test_authenticated_sse_stream_uses_existing_attachment():
    with tempfile.TemporaryDirectory() as temporary:
        runtime = Path(temporary) / "runtime"
        jobs = Path(temporary) / "jobs"
        runtime.mkdir()
        jobs.mkdir()
        unit = "ultimate-updater-update-sse-1"
        broker = WEB.InteractiveJobBroker(runtime)
        socket_path = broker.socket_path(unit)
        socket_path.parent.mkdir(parents=True)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        listener.listen(1)
        release = threading.Event()

        def accept_client():
            client, _ = listener.accept()
            client.recv(64)
            client.sendall(bytes([0x1b]) + b"[31mraw" + bytes([0xff, 0x00, 0x0a]))
            release.wait(2)
            client.close()

        threading.Thread(target=accept_client, daemon=True).start()
        (jobs / f"{unit}.state").write_text(
            f"unit={unit}\ntarget=900\nstate=running\ninteractive=true\nsocket_path={socket_path}\n",
            encoding="utf-8",
        )

        class Auth:
            configured = True

            def __init__(self):
                self.items = {"session-token": {"user": "root", "csrf": "csrf-token", "expires": time.time() + 60}}

            def session(self, token):
                return self.items.get(token)

        server = WEB.ThreadedHTTPServer(("127.0.0.1", 0), WEB.StatusHandler) if hasattr(WEB, "ThreadedHTTPServer") else WEB.ThreadingHTTPServer(("127.0.0.1", 0), WEB.StatusHandler)
        server.auth = Auth()
        server.jobs_dir = jobs
        server.interactive_broker = broker
        server.status_file = Path(temporary) / "status.json"
        server.config_file = Path(temporary) / "update.conf"
        server.inventory_file = Path(temporary) / "targets.conf"
        server.tls_enabled = False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        cookie = "UU_SESSION=session-token"
        origin = f"http://127.0.0.1:{server.server_port}"
        try:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("GET", f"/api/jobs/{unit}/stream?attachment_id=invalid")
            unauthenticated = connection.getresponse()
            assert unauthenticated.status == 401, unauthenticated.status
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("POST", f"/api/jobs/{unit}/attach", body="{}", headers={
                "Content-Type": "application/json", "Cookie": cookie, "Origin": origin, "X-CSRF-Token": "csrf-token",
            })
            attach_response = connection.getresponse()
            assert attach_response.status == 200
            attachment_id = json.loads(attach_response.read())["attachment_id"]
            connection.close()
            assert server.interactive_broker.valid_attachment_id(attachment_id)

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("POST", f"/api/jobs/{unit}/resize", body=json.dumps({
                "attachment_id": attachment_id, "rows": 34, "cols": 118,
            }), headers={
                "Content-Type": "application/json", "Cookie": cookie, "Origin": origin,
                "X-CSRF-Token": "csrf-token",
            })
            assert connection.getresponse().status == 200
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("POST", f"/api/jobs/{unit}/resize", body=json.dumps({
                "attachment_id": attachment_id, "rows": 1, "cols": 118,
            }), headers={
                "Content-Type": "application/json", "Cookie": cookie, "Origin": origin,
                "X-CSRF-Token": "csrf-token",
            })
            assert connection.getresponse().status == 400
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("POST", f"/api/jobs/{unit}/input", body=json.dumps({
                "attachment_id": "A" * 32, "data": base64.b64encode(b"x").decode("ascii"),
            }), headers={
                "Content-Type": "application/json", "Cookie": cookie, "Origin": origin, "X-CSRF-Token": "csrf-token",
            })
            assert connection.getresponse().status == 409
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("GET", f"/api/jobs/{unit}/stream?attachment_id={attachment_id}", headers={
                "Cookie": cookie, "Origin": "https://not-the-ui.example",
            })
            assert connection.getresponse().status == 403
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=3)
            connection.request("GET", f"/api/jobs/{unit}/stream?attachment_id={attachment_id}", headers={
                "Cookie": cookie, "Origin": origin, "Last-Event-ID": "0",
            })
            stream = connection.getresponse()
            assert stream.status == 200
            lines = []
            while "event: output\n" not in lines:
                line = stream.readline().decode("utf-8")
                assert line
                lines.append(line)
            encoded = stream.readline().decode("utf-8").split("data: ", 1)[1].strip()
            assert base64.b64decode(encoded) == bytes([0x1b]) + b"[31mraw" + bytes([0xff, 0x00, 0x0a])

            release.set()
            closed = False
            while True:
                line = stream.readline().decode()
                assert line
                if line == "event: closed\n":
                    closed = True
                    break
            assert closed
            stream.close()
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            listener.close()


def test_webui_exposes_only_authenticated_input_actions():
    source = (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert 'parts[3] == "attach"' in source
    assert 'parts[3] == "input"' in source
    assert 'parts[3] == "resize"' in source
    assert 'parts[3] == "detach"' in source
    assert 'parts[3] == "stream"' in source
    assert "text/event-stream" in source
    assert "Last-Event-ID" in source
    assert "attachment_id" in source
    assert "window.addEventListener('pagehide'" not in source
    assert "self.write_allowed()" in source
    assert "The interactive job socket is unavailable." in source
    assert "Interactive terminal available" in WEB.PAGE


def test_journal_output_records_preserve_cursor_ansi_and_line_bytes():
    record = json.dumps({"__CURSOR": "s=cursor-1", "MESSAGE": "\u001b[31mfailed"}).encode()
    cursor, data = WEB.StatusHandler.journal_output_record(record)
    assert cursor == "s=cursor-1"
    assert data == b"\x1b[31mfailed\r\n"
    assert WEB.StatusHandler.journal_output_record(
        json.dumps({"__CURSOR": "s=cursor-2", "MESSAGE": "one\ntwo"}).encode()
    )[1] == b"one\r\ntwo\r\n"
    assert WEB.StatusHandler.journal_output_record(
        json.dumps({"__CURSOR": "s=cursor-3", "MESSAGE": "one\r\ntwo\r\n"}).encode()
    )[1] == b"one\r\ntwo\r\n"
    assert WEB.StatusHandler.journal_output_record(
        json.dumps({"__CURSOR": "s=cursor-4", "MESSAGE": "first\nsecond\n"}).encode()
    )[1] == b"first\r\nsecond\r\n"
    assert WEB.StatusHandler.journal_output_record(b"not-json") is None


def test_live_output_uses_job_bound_read_only_journal_stream():
    source = (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert 'parts[3] == "output-stream"' in source
    assert "journalctl" in source
    assert '"--follow"' in source
    assert '"--output=json"' in source
    assert '"--after-cursor"' in source
    assert '"--lines", "200"' in source
    assert "direct_job_record(unit)" in source
    assert "JOB_STREAM_UNAVAILABLE" in source
    assert "Interactive jobs use the terminal stream." in source
    assert "disableStdin:true" in WEB.PAGE
    assert "output-stream`" in WEB.PAGE
    assert "openLiveOutput" in WEB.PAGE
    assert "data-live-job" in WEB.PAGE
    assert "Live output" in WEB.PAGE
    assert "interactiveKeybarVisibility(false)" in WEB.PAGE
    assert "/api/jobs/${encodeURIComponent(unit)}/input" in WEB.PAGE
    assert "X-CSRF-Token" in WEB.PAGE
    assert "new MutationObserver(()=>decorateInteractiveJobs())" not in WEB.PAGE


def test_local_xterm_terminal_assets_and_stable_panel():
    assets = ROOT / "web-ui" / "assets" / "vendor" / "xterm"
    assert (assets / "xterm.js").is_file()
    assert (assets / "xterm.css").is_file()
    assert (assets / "LICENSE").is_file()
    assert (assets / "addon-fit.LICENSE").is_file()
    assert "/assets/vendor/xterm/xterm.js" in WEB.PAGE
    assert "/assets/vendor/xterm/xterm.css" in WEB.PAGE
    assert "/assets/vendor/xterm/addon-fit.js" in WEB.PAGE
    assert "https://" not in WEB.PAGE.split("/assets/vendor/xterm/xterm.js", 1)[0]
    assert "new Terminal({scrollback:2000,convertEol:false,fontSize})" in WEB.PAGE
    assert "new FitAddon.FitAddon()" in WEB.PAGE
    assert "terminal.onData(queueInteractiveInput)" in WEB.PAGE
    assert "disableStdin:true" in WEB.PAGE
    assert "/api/jobs/${encodeURIComponent(state.unit)}/resize" in WEB.PAGE
    assert "UU_RESIZE" in (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert "Ctrl-C detaches from the terminal" in WEB.PAGE
    assert "Attach input" not in WEB.PAGE
    assert "data-interactive-input" not in WEB.PAGE
    assert "new EventSource(`/api/jobs/${encodeURIComponent(unit)}/stream" in WEB.PAGE
    assert "terminal.write(terminalBytes(event.data))" in WEB.PAGE
    assert 'id="interactive-terminal-status"' in WEB.PAGE
    assert 'id="interactive-terminal-message"' in WEB.PAGE
    assert "const terminalStatus=(value,error=false)=>{const node=document.getElementById('interactive-terminal-status');if(!node)return;" in WEB.PAGE
    assert "const terminalMessage=(value,visible=true)=>{const node=document.getElementById('interactive-terminal-message');if(!node)return;" in WEB.PAGE
    assert "const heading=document.getElementById('interactive-terminal-heading'),help=document.getElementById('interactive-terminal-help');if(heading)heading.textContent='Live terminal';if(help)help.hidden=false" in WEB.PAGE
    assert "const title=document.getElementById('interactive-terminal-title'),download=document.getElementById('interactive-terminal-download');if(title)title.textContent" in WEB.PAGE
    assert "panel.hidden=false;interactiveKeybarState(true);terminalMessage(message,true);terminalStatus('Stream unavailable',true)" in WEB.PAGE
    assert 'protocol_version = "HTTP/1.1"' in (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert 'self.send_header("Connection", "keep-alive")' in (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
    assert "panel.hidden=false;interactiveKeybarState(true);terminalMessage(message,true);terminalStatus('Stream unavailable',true)" in WEB.PAGE
    assert "catch(error){await disposeInteractiveTerminal(true);notice(error.message||'The interactive terminal could not be opened.',true)}" not in WEB.PAGE
    assert "new Uint8Array(binary.length)" in WEB.PAGE
    assert "interactiveKeyData" in WEB.PAGE
    assert "data-interactive-key=\"Escape\"" in WEB.PAGE
    assert "data-interactive-key=\"Enter\"" in WEB.PAGE
    assert "window.visualViewport?.addEventListener('resize'" in WEB.PAGE
    assert "window.visualViewport?.removeEventListener('resize'" in WEB.PAGE
    assert "height:100dvh" in WEB.PAGE
    assert "font-size:11px" in WEB.PAGE
    assert "@media(max-width:720px)" in WEB.PAGE
    assert "TERMINAL_FONT_MIN=8" in WEB.PAGE
    assert "TERMINAL_FONT_MAX=16" in WEB.PAGE
    assert "ultimate-updater-terminal-font-size" in WEB.PAGE
    assert "localStorage" in WEB.PAGE
    assert "interactive-terminal-font-decrease" in WEB.PAGE
    assert "interactive-terminal-font-increase" in WEB.PAGE
    assert 'aria-label="Close terminal"' in WEB.PAGE
    assert "interactive-terminal-close-icon" in WEB.PAGE
    assert "interactive-terminal-keybar" in WEB.PAGE
    jobs_position = WEB.PAGE.index('<section id="jobs"')
    terminal_position = WEB.PAGE.index('<section id="interactive-terminal-panel"')
    assert terminal_position > jobs_position
    assert ".interactive-terminal-panel { position:fixed;" in WEB.PAGE
    assert 'class="interactive-terminal-dialog" role="dialog"' in WEB.PAGE
    assert "data-interactive-terminal" in WEB.PAGE
    assert "Live terminal" in WEB.PAGE
    assert "const jobTitle=job=>" in WEB.PAGE
    assert "friendlyTarget({id:job.target})" not in WEB.PAGE
    assert "window.addEventListener('pagehide'" not in WEB.PAGE
    installer = (ROOT / "install.sh").read_text(encoding="utf-8")
    assert "assets/vendor/xterm/xterm.js" in installer
    assert "assets/vendor/xterm/xterm.css" in installer
    assert "assets/vendor/xterm/addon-fit.js" in installer
    assert "assets/vendor/xterm/addon-fit.LICENSE" in installer


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
test_broker_resize_uses_existing_attachment_socket_and_validates()
test_broker_replays_exact_bytes_with_sequences_and_wakes_waiter()
test_attachment_lifecycle_and_stream_grace()
test_authenticated_sse_stream_uses_existing_attachment()
test_local_xterm_terminal_assets_and_stable_panel()
test_webui_exposes_only_authenticated_input_actions()
test_journal_output_records_preserve_cursor_ansi_and_line_bytes()
test_live_output_uses_job_bound_read_only_journal_stream()
test_interactive_lookup_reads_requested_state_directly()
print("web interactive UI tests: PASS")
