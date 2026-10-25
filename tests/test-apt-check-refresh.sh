#!/usr/bin/env bash
# shellcheck disable=SC2016 # Source assertions intentionally use literals.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir "$WORK_DIR/fake-bin"
cat > "$WORK_DIR/fake-bin/apt-get" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == update ]] || exit 64
printf 'refresh\n' >> "$APT_REFRESH_LOG"
exit "${APT_REFRESH_RC:-0}"
SH
chmod 755 "$WORK_DIR/fake-bin/apt-get"

cat > "$WORK_DIR/apt-count.py" <<'PY'
import os

with open(os.environ["APT_COUNT_LOG"], "a", encoding="utf-8") as log:
    log.write("count\n")
print("APT_COUNTS|2|1|1|true")
PY

cat > "$WORK_DIR/apt-count.sh" <<'SH'
#!/usr/bin/env sh
printf 'count\n' >> "$APT_COUNT_LOG"
printf 'APT_COUNTS|2|1|1|true\n'
SH
chmod 755 "$WORK_DIR/apt-count.sh"

export PATH="$WORK_DIR/fake-bin:$PATH"
export LOCAL_FILES="$WORK_DIR"
export APT_COUNT_SCRIPT="$WORK_DIR/apt-count.py"
export APT_COUNT_SHELL_SCRIPT="$WORK_DIR/apt-count.sh"
export APT_REFRESH_LOG="$WORK_DIR/refresh.log"
export APT_COUNT_LOG="$WORK_DIR/count.log"

source "$ROOT_DIR/target-runtime.sh"

READ_APT_UPDATE_COUNTS
[[ "$APT_COUNTS_TOTAL" == 2 ]]
[[ "$NORMAL_APT_UPDATES" == 1 ]]
[[ "$SECURITY_APT_UPDATES" == 1 ]]
[[ "$(cat "$WORK_DIR/refresh.log")" == refresh ]]
[[ "$(cat "$WORK_DIR/count.log")" == count ]]

: > "$WORK_DIR/refresh.log"
: > "$WORK_DIR/count.log"
export APT_REFRESH_RC=42
if READ_APT_UPDATE_COUNTS; then
  echo 'failed APT refresh unexpectedly succeeded' >&2
  exit 1
fi
[[ "$APT_COUNTS_TOTAL" == null ]]
[[ "$NORMAL_APT_UPDATES" == null ]]
[[ "$SECURITY_APT_UPDATES" == null ]]
[[ "$(cat "$WORK_DIR/refresh.log")" == refresh ]]
[[ ! -s "$WORK_DIR/count.log" ]]
unset APT_REFRESH_RC

remote_command=$(APT_COUNT_REMOTE_COMMAND)
: > "$WORK_DIR/refresh.log"
: > "$WORK_DIR/count.log"
remote_output=$(bash -c "$remote_command")
[[ "$remote_output" == 'APT_COUNTS|2|1|1|true' ]]
[[ "$(cat "$WORK_DIR/refresh.log")" == refresh ]]
[[ "$(cat "$WORK_DIR/count.log")" == count ]]

export APT_REFRESH_RC=42
if bash -c "$remote_command" > "$WORK_DIR/remote-failed.out"; then
  echo 'failed remote APT refresh unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -s "$WORK_DIR/remote-failed.out" ]]
unset APT_REFRESH_RC

# The same generated command is used by pct/LXC, SSH VM, QGA VM and the
# External-APT SSH protocol; only the surrounding transport differs.
grep -Fq 'RUN_PCT_COMMAND "$CONTAINER" bash -c "$apt_count_command"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" "$apt_count_command"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'QEMU_GUEST_EXEC_READONLY "$VM" --timeout 120 -- bash -c "$apt_count_command"' "$ROOT_DIR/check-updates.sh"
grep -Fq 'bash -c "$UU_APT_COUNT_COMMAND"' "$ROOT_DIR/external-apt.sh"

echo 'APT check refresh and fail-closed tests: PASS'
