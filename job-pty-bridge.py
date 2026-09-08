#!/usr/bin/env python3
"""Small detached PTY bridge for an individual Ultimate Updater job.

The bridge deliberately exposes only the child's PTY, never a shell command
interface.  The job runner owns the socket directory and systemd owns the
bridge process.
"""

import argparse
import errno
import fcntl
import os
import pty
import select
import selectors
import shutil
import socket
import sys
import struct
import termios
import time
import tty


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser.parse_args()


def make_socket(path):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    os.chmod(path, 0o600)
    server.listen(8)
    server.setblocking(False)
    return server


def write_pty_data(master_fd, data):
    """Apply the private resize frame, then forward user input verbatim."""
    if data.startswith(b"\x00UU_RESIZE "):
        header, separator, remainder = data.partition(b"\n")
        if separator:
            try:
                rows, columns = (int(value) for value in header[11:].split())
                if 1 <= rows <= 500 and 1 <= columns <= 500:
                    fcntl.ioctl(
                        master_fd,
                        termios.TIOCSWINSZ,
                        struct.pack("HHHH", rows, columns, 0, 0),
                    )
            except (ValueError, OSError):
                pass
            data = remainder
    if data:
        os.write(master_fd, data)


def client_disconnected(client):
    """Detect a peer that vanished while the bridge was not reading input."""
    try:
        return client.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b""
    except BlockingIOError:
        return False
    except OSError:
        return True


def client_events(selector, client, writable):
    events = selectors.EVENT_READ | (selectors.EVENT_WRITE if writable else 0)
    selector.modify(client, events, "client")


def flush_pending(client, pending):
    if not pending:
        return True
    try:
        sent = client.send(pending)
    except BlockingIOError:
        return False
    except OSError:
        return None
    del pending[:sent]
    return True


def flush_client_before_exit(selector, client, pending, timeout=1.0):
    deadline = time.monotonic() + timeout
    while pending and time.monotonic() < deadline:
        result = flush_pending(client, pending)
        if result is None:
            return False
        if pending:
            selector.select(timeout=min(0.05, max(0, deadline - time.monotonic())))
    return not pending


def run_bridge(socket_path, command):
    if not command:
        print("PTY bridge: missing child command", file=sys.stderr)
        return 2

    server = make_socket(socket_path)
    child_pid, master_fd = pty.fork()
    if child_pid == 0:
        os.execvp(command[0], command)

    os.set_blocking(master_fd, False)
    selector = selectors.DefaultSelector()
    selector.register(master_fd, selectors.EVENT_READ, "pty")
    client = None
    client_pending = bytearray()
    backlog = bytearray()
    max_backlog = 1024 * 1024
    try:
        while True:
            if client is not None and client_disconnected(client):
                selector.unregister(client)
                client.close()
                client = None
                client_pending.clear()
            try:
                connection, _ = server.accept()
                connection.setblocking(False)
                if client is not None:
                    try:
                        connection.sendall(b"BUSY: another input client is attached\n")
                    except OSError:
                        # A rejected short-lived client may disconnect before
                        # it reads the diagnostic.  It must never terminate
                        # the detached job or its primary input bridge.
                        pass
                    connection.close()
                else:
                    client = connection
                    client_pending = bytearray(backlog)
                    selector.register(client, selectors.EVENT_READ, "client")
                    if client_pending:
                        client_events(selector, client, True)
            except BlockingIOError:
                pass

            for key, mask in selector.select(timeout=0.2):
                if key.data == "pty":
                    try:
                        data = os.read(master_fd, 8192)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            data = b""
                        else:
                            raise
                    if not data:
                        if client is not None:
                            flush_client_before_exit(selector, client, client_pending)
                        _, status = os.waitpid(child_pid, 0)
                        return os.waitstatus_to_exitcode(status)
                    backlog.extend(data)
                    if len(backlog) > max_backlog:
                        del backlog[:-max_backlog]
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()
                    if client is not None:
                        client_pending.extend(data)
                        if len(client_pending) > max_backlog:
                            del client_pending[:-max_backlog]
                        client_events(selector, client, True)
                else:
                    if mask & selectors.EVENT_WRITE:
                        result = flush_pending(client, client_pending)
                        if result is None:
                            selector.unregister(client)
                            client.close()
                            client = None
                            client_pending.clear()
                            continue
                        if not client_pending:
                            client_events(selector, client, False)
                    if client is not None and mask & selectors.EVENT_READ:
                        try:
                            data = client.recv(8192)
                        except OSError:
                            data = b""
                        if not data:
                            selector.unregister(client)
                            client.close()
                            client = None
                            client_pending.clear()
                        else:
                            write_pty_data(master_fd, data)
    finally:
        try:
            selector.unregister(master_fd)
        except Exception:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass
        if client is not None:
            try:
                selector.unregister(client)
            except Exception:
                pass
            client.close()
        server.close()
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        try:
            os.rmdir(os.path.dirname(socket_path))
        except OSError:
            pass


def attach(socket_path):
    if not os.path.exists(socket_path):
        print(f"Interactive job socket not found: {socket_path}", file=sys.stderr)
        return 1
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.connect(socket_path)
    except OSError as error:
        print(f"Could not attach to interactive job: {error}", file=sys.stderr)
        return 1

    old_terminal = None
    if sys.stdin.isatty():
        old_terminal = termios.tcgetattr(sys.stdin.fileno())
        tty.setraw(sys.stdin.fileno())
    try:
        if sys.stdin.isatty():
            size = shutil.get_terminal_size((80, 24))
            connection.sendall(f"\x00UU_RESIZE {size.lines} {size.columns}\n".encode())
        while True:
            readable, _, _ = select.select([connection, sys.stdin.fileno()], [], [])
            if connection in readable:
                data = connection.recv(8192)
                if not data:
                    return 0
                if data.startswith(b"BUSY:"):
                    sys.stderr.buffer.write(data)
                    sys.stderr.buffer.flush()
                    return 2
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
            if sys.stdin.fileno() in readable:
                data = os.read(sys.stdin.fileno(), 8192)
                if not data:
                    return 0
                # Ctrl-C detaches this client instead of signalling the
                # detached package manager through the PTY.
                if b"\x03" in data:
                    return 0
                connection.sendall(data)
    finally:
        if old_terminal is not None:
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old_terminal)
        connection.close()


def main():
    args = parse_args()
    if args.command and args.command[0] == "attach":
        if len(args.command) != 2:
            return 2
        return attach(args.command[1])
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    return run_bridge(args.socket, command)


if __name__ == "__main__":
    raise SystemExit(main())
