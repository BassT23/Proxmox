#!/bin/bash
set -euo pipefail

# Synthetic PTY harness for the #333 process-group condition. This is test
# infrastructure only; the product must not acquire a hard timeout.
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

ROOT_DIR="$ROOT_DIR" WORK_DIR="$WORK_DIR" python3 - <<'PY'
import errno
import fcntl
import os
import pty
import signal
import subprocess
import sys
import termios
import time
from pathlib import Path

work = Path(os.environ["WORK_DIR"])
helper = work / "pty-helper.py"
helper.write_text(
    """#!/usr/bin/env python3
import fcntl, os, signal, subprocess, termios
from pathlib import Path

log = Path(os.environ['HELPER_LOG'])
try:
    tty = os.ttyname(0)
    with open(tty, 'rb', buffering=0) as terminal:
        tpgid = fcntl.ioctl(terminal.fileno(), termios.TIOCGPGRP, b'\\0' * 4)
        tpgid = int.from_bytes(tpgid, byteorder='little', signed=True)
except OSError:
    tty, tpgid = 'none', 'none'
values = [f'pid={os.getpid()}', f'ppid={os.getppid()}',
          f'pgid={os.getpgrp()}', f'sid={os.getsid(0)}',
          f'tty={tty}', f'tpgid={tpgid}',
          f'state_before={open(f'/proc/{os.getpid()}/stat').read().split()[2]}']
log.write_text('\\n'.join(values) + '\\n')
signal.signal(signal.SIGTTOU, signal.SIG_DFL)
stty = subprocess.Popen(['stty', 'sane'], stdin=0, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
Path(os.environ['STTY_LOG']).write_text(f'pid={stty.pid}\\npgid={os.getpgid(stty.pid)}\\n')
if os.environ.get('FORCE_SIGTTOU') == '1':
    # Deterministic fallback for hosts where coreutils stty ignores SIGTTOU:
    # inject the same job-control stop after proving the background PGID.
    os.kill(stty.pid, signal.SIGTTOU)
stty.wait()
with log.open('a') as output:
    output.write(f'stty_rc={stty.returncode}\\n')
    output.write('after=yes\\n')
""",
    encoding="utf-8",
)
helper.chmod(0o755)


def run(mode):
    log = work / f"{mode}.log"
    stty_log = work / f"{mode}.stty"
    command = (
        "stty tostop; set -m; "
        f"FORCE_SIGTTOU={'1' if mode == 'old' else '0'} HELPER_LOG={log!s} "
        f"STTY_LOG={stty_log!s} "
        f"{sys.executable} {helper!s} "
        f"{'< /dev/tty' if mode == 'old' else '< /dev/null'} | tee {work / mode}.out & wait"
    )
    pid, master = pty.fork()
    if pid == 0:
        os.execl('/bin/bash', 'bash', '-c', command)
    os.set_blocking(master, False)
    child_state = "running"
    stty_stopped = False
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            os.read(master, 4096)
        except BlockingIOError:
            pass
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
        stty_file = stty_log
        if stty_file.exists():
            stty_pid = int(stty_file.read_text(encoding="utf-8").splitlines()[0].split("=", 1)[1])
            try:
                state = Path(f"/proc/{stty_pid}/stat").read_text(encoding="utf-8").split()[2]
                stty_stopped = stty_stopped or state == "T"
            except FileNotFoundError:
                pass
        waited, status = os.waitpid(pid, os.WNOHANG)
        if waited:
            child_state = f"exit={os.waitstatus_to_exitcode(status)}"
            break
        time.sleep(0.05)
    if child_state == "running":
        os.killpg(pid, signal.SIGKILL)
        _, status = os.waitpid(pid, 0)
        child_state = f"watchdog={os.waitstatus_to_exitcode(status)}"
    os.close(master)
    return log, stty_log, child_state, stty_stopped


old_log, old_stty, old_state, old_stty_stopped = run("old")
new_log, _, new_state, new_stty_stopped = run("new")
old = old_log.read_text(encoding="utf-8") if old_log.exists() else ""
new = new_log.read_text(encoding="utf-8") if new_log.exists() else ""
old_stty_text = old_stty.read_text(encoding="utf-8") if old_stty.exists() else ""
assert "pgid=" in old and "tpgid=" in old, old
old_values = dict(line.split("=", 1) for line in old.splitlines() if "=" in line)
stty_values = dict(line.split("=", 1) for line in old_stty_text.splitlines() if "=" in line)
assert old_values["pgid"] != old_values["tpgid"], old
assert old_state.startswith("watchdog="), (old_state, old)
assert stty_values["pgid"] != old_values["tpgid"], (old_stty_text, old)
assert old_stty_stopped, (old_stty_text, old)
assert "after=yes" not in old, old
assert new_state.startswith("exit="), (new_state, new)
assert "after=yes" in new, new
assert not new_stty_stopped, new
new_values = dict(line.split("=", 1) for line in new.splitlines() if "=" in line)
assert new_values["stty_rc"] != "0"

print("Community-Scripts PTY job-control regression: PASS")
print(f"PRE_FIX_PGID={old_values['pgid']} PRE_FIX_TPGID={old_values['tpgid']} PRE_FIX_STATE={old_state}")
print(f"POST_FIX_STTY_RC={new_values['stty_rc']} POST_FIX_STATE={new_state}")
PY

# shellcheck disable=SC2016 # assert the literal product command.
grep -Fq '"$COMMUNITY_UPDATE_COMMAND" </dev/null 2>&1 | tee' "$ROOT_DIR/update-extras.sh"
if grep -Fq 'timeout 1800s' "$ROOT_DIR/update-extras.sh"; then
  echo 'community helper path must not reintroduce the old hard timeout' >&2
  exit 1
fi
