#!/usr/bin/env python3
"""Regression tests for the detached PTY bridge used by interactive jobs."""

import socket
import os
import select
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "job-pty-bridge.py"


def wait_for_socket(path):
    deadline = time.time() + 5
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise AssertionError(f"socket did not appear: {path}")


def receive_until(connection, marker, timeout=5):
    connection.settimeout(timeout)
    data = bytearray()
    while marker not in data:
        chunk = connection.recv(8192)
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def receive_process_until(process, marker, timeout=5):
    deadline = time.time() + timeout
    data = bytearray()
    while marker not in data and time.time() < deadline:
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if not readable:
            continue
        chunk = os.read(process.stdout.fileno(), 8192)
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def main():
    with tempfile.TemporaryDirectory(prefix="uu-pty-test-") as temporary:
        directory = Path(temporary) / "job"
        socket_path = directory / "control.sock"
        command = [
            str(BRIDGE),
            "--socket",
            str(socket_path),
            "--",
            "/bin/bash",
            "-lc",
            "printf READY; read -r value; printf 'GOT:%s\\n' \"$value\"; printf READY2; read -r second; printf 'DONE:%s\\n' \"$second\"",
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        backlog_server = None
        try:
            wait_for_socket(socket_path)
            assert directory.stat().st_mode & 0o777 == 0o700
            assert socket_path.stat().st_mode & 0o777 == 0o600

            first = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            first.connect(str(socket_path))
            assert b"READY" in receive_until(first, b"READY")
            first.sendall(b"one\n")

            second_writer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            second_writer.connect(str(socket_path))
            assert b"BUSY" in receive_until(second_writer, b"BUSY")
            second_writer.close()

            assert b"READY2" in receive_until(first, b"READY2")
            first.close()

            second = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            second.connect(str(socket_path))
            second_initial = receive_until(second, b"READY2")
            assert b"READY2" in second_initial
            second.sendall(b"two\n")
            output = second_initial + receive_until(second, b"DONE:two")
            second.close()
            assert b"GOT:one" in output
            assert b"DONE:two" in output

            assert process.wait(timeout=5) == 0
            assert not socket_path.exists()
            assert not directory.exists()

            attach_socket = directory / "attach.sock"
            attach_server = subprocess.Popen([
                str(BRIDGE), "--socket", str(attach_socket), "--", "/bin/bash", "-lc",
                "printf READY; read -r value; printf 'ATTACHED:%s\\n' \"$value\"",
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            wait_for_socket(attach_socket)
            attach = subprocess.Popen([
                "python3", str(BRIDGE), "--socket", str(attach_socket),
                "attach", str(attach_socket),
            ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            attach_output = receive_process_until(attach, b"READY")
            attach.stdin.write(b"attached\n")
            attach.stdin.flush()
            attach_output += receive_process_until(attach, b"ATTACHED:attached")
            assert b"ATTACHED:attached" in attach_output
            attach.stdin.close()
            assert attach.wait(timeout=5) == 0
            assert attach_server.wait(timeout=5) == 0

            backlog_socket = directory / "backlog.sock"
            backlog_size = 1024 * 1024
            backlog_server = subprocess.Popen([
                str(BRIDGE), "--socket", str(backlog_socket), "--", "python3", "-c",
                f"import sys,time;sys.stdout.buffer.write(b'X'*{backlog_size});sys.stdout.flush();time.sleep(1)",
            ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            wait_for_socket(backlog_socket)
            time.sleep(0.25)
            backlog_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            backlog_client.settimeout(5)
            backlog_client.connect(str(backlog_socket))
            backlog = bytearray()
            while len(backlog) < backlog_size:
                chunk = backlog_client.recv(65536)
                if not chunk:
                    break
                backlog.extend(chunk)
            backlog_client.close()
            assert len(backlog) == backlog_size
            assert backlog == b"X" * backlog_size
            assert backlog_server.wait(timeout=5) == 0
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
            if backlog_server is not None and backlog_server.poll() is None:
                backlog_server.terminate()
                backlog_server.wait(timeout=5)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()

    print("interactive PTY bridge tests: PASS")


if __name__ == "__main__":
    main()
