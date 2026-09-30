#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

awk '/^RUN_UPDATE_COMMAND\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/update.sh" > "$WORK_DIR/runtime.sh"
cat > "$WORK_DIR/mutator" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$MUTATOR_MODE" >> "$MUTATOR_COUNT"
printf 'stdout from mutator\n'
printf 'stderr from mutator\n' >&2
exit "${MUTATOR_RC:-23}"
EOF
chmod +x "$WORK_DIR/mutator"

run_case() {
  local mode=$1
  : > "$WORK_DIR/count-$mode"
  set +e
  output=$(MUTATOR_MODE="$mode" MUTATOR_COUNT="$WORK_DIR/count-$mode" RUN_MODE="$mode" \
    MUTATOR_RC=23 bash -c \
    'source "$1"; EFFECTIVE_HEADLESS() { [[ "$RUN_MODE" == headless ]]; }; RUN_UPDATE_COMMAND "$2/mutator"' \
    _ "$WORK_DIR/runtime.sh" "$WORK_DIR" 2>&1)
  local rc=$?
  set -e
  [[ $rc -eq 23 ]]
  [[ $(wc -l < "$WORK_DIR/count-$mode") -eq 1 ]]
  grep -Fq 'stdout from mutator' <<<"$output"
  grep -Fq 'stderr from mutator' <<<"$output"
}

run_case headless
run_case interactive

# Exercise the same extracted production function through a real controlling
# PTY.  The child must see native terminal descriptors and receive input
# without a tee/script wrapper in the production runtime.
WORK_DIR="$WORK_DIR" python3 - <<'PY'
import errno
import os
import pty
import select
import shlex
import time

work = os.environ["WORK_DIR"]
child = os.path.join(work, "interactive-child")
count = os.path.join(work, "interactive-count")
open(count, "w", encoding="utf-8").close()
with open(child, "w", encoding="utf-8") as output:
    output.write("""#!/usr/bin/env bash
set -euo pipefail
[[ -t 0 ]] && stdin_tty=PASS || stdin_tty=FAIL
[[ -t 1 ]] && stdout_tty=PASS || stdout_tty=FAIL
[[ -t 2 ]] && stderr_tty=PASS || stderr_tty=FAIL
printf 'CHILD_STDIN_TTY=%s\\n' "$stdin_tty"
printf 'CHILD_STDOUT_TTY=%s\\n' "$stdout_tty"
printf 'CHILD_STDERR_TTY=%s\\n' "$stderr_tty" >&2
printf 'PROMPT> '
IFS= read -r value
printf 'VALUE=%s\\n' "$value"
printf 'CHILD_EXECUTION\\n' >> "$INTERACTIVE_COUNT"
printf 'STDERR_VISIBLE\\n' >&2
exit 29
""")
os.chmod(child, 0o755)

command = (
    "source %s; EFFECTIVE_HEADLESS() { return 1; }; RUN_UPDATE_COMMAND %s"
    % (shlex.quote(os.path.join(work, "runtime.sh")), shlex.quote(child))
)
pid, master = pty.fork()
if pid == 0:
    env = os.environ.copy()
    env["INTERACTIVE_COUNT"] = count
    os.execve("/bin/bash", ["bash", "-c", command], env)

os.set_blocking(master, False)
captured = bytearray()
sent = False
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    readable, _, _ = select.select([master], [], [], 0.1)
    if readable:
        try:
            data = os.read(master, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                data = b""
            else:
                raise
        captured.extend(data)
        if b"PROMPT>" in captured and not sent:
            os.write(master, b"native-input\n")
            sent = True
    waited, status = os.waitpid(pid, os.WNOHANG)
    if waited:
        break
else:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    raise AssertionError("interactive runtime did not return")

try:
    rc = os.waitstatus_to_exitcode(status)
except UnboundLocalError:
    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
text = captured.decode(errors="replace")
assert sent, text
assert "CHILD_STDIN_TTY=PASS" in text, text
assert "CHILD_STDOUT_TTY=PASS" in text, text
assert "CHILD_STDERR_TTY=PASS" in text, text
assert "VALUE=native-input" in text, text
assert "STDERR_VISIBLE" in text, text
assert rc == 29, (rc, text)
assert open(count, encoding="utf-8").read().splitlines() == ["CHILD_EXECUTION"]
print("interactive PTY runtime tests: PASS")
PY

runtime_source=$(awk '/^RUN_UPDATE_COMMAND\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$ROOT_DIR/update.sh")
if grep -Fq 'tee' <<<"$runtime_source" || grep -Fq 'script' <<<"$runtime_source"; then
  echo 'interactive runtime must not introduce terminal wrappers' >&2
  exit 1
fi

echo 'single-execution runtime tests: PASS'
