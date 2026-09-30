#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/apt-count.py" <<'PY'
print("UU_APT_COUNTS|3|1|2|true")
PY
cat > "$WORK_DIR/rpm-count.py" <<'PY'
print("UU_RPM_COUNTS|ok|4|null|null|false")
PY
cat > "$WORK_DIR/package-count.sh" <<'SH'
#!/usr/bin/env sh
printf 'UU_PACKAGE_COUNTS|ok|%s|5|null|null|false\n' "$1"
SH
chmod +x "$WORK_DIR/package-count.sh"

LOCAL_FILES="$WORK_DIR" \
APT_COUNT_SCRIPT="$WORK_DIR/apt-count.py" \
RPM_COUNT_SCRIPT="$WORK_DIR/rpm-count.py" \
PACKAGE_COUNT_SCRIPT="$WORK_DIR/package-count.sh" \
bash -c 'source "$1"; APT_COUNT_REMOTE_COMMAND > "$2/apt.command"; RPM_COUNT_REMOTE_COMMAND > "$2/rpm.command"; PACKAGE_COUNT_REMOTE_COMMAND pkg > "$2/pkg.command"; PACKAGE_COUNT_REMOTE_COMMAND pacman > "$2/pacman.command"; PACKAGE_COUNT_REMOTE_COMMAND apk > "$2/apk.command"' \
  _ "$ROOT_DIR/target-runtime.sh" "$WORK_DIR"

# OpenSSH flattens all command arguments into one remote shell string.  This
# fixture models that behavior; an extra `bash -c`/`sh -c` therefore changes
# the command contract and must not be inserted by the caller.
ssh_flattened() {
  local host="$1" port="$2" user="$3"
  shift 3
  : "$host" "$port" "$user"
  local remote_command="$*"
  bash -c "$remote_command"
}

run_good() {
  local command_file="$1" expected="$2"
  local result
  result=$(ssh_flattened test-host 22 root "$(<"$command_file")")
  [[ "$result" == "$expected" ]]
}

run_bad_wrapper() {
  local command_file="$1"
  local result
  result=$(ssh_flattened test-host 22 root bash -c "$(<"$command_file")" 2>/dev/null) || return 1
  [[ "$result" == *UU_* ]]
}

run_good "$WORK_DIR/apt.command" 'UU_APT_COUNTS|3|1|2|true'
run_good "$WORK_DIR/rpm.command" 'UU_RPM_COUNTS|ok|4|null|null|false'
run_good "$WORK_DIR/pkg.command" 'UU_PACKAGE_COUNTS|ok|pkg|5|null|null|false'
run_good "$WORK_DIR/pacman.command" 'UU_PACKAGE_COUNTS|ok|pacman|5|null|null|false'
run_good "$WORK_DIR/apk.command" 'UU_PACKAGE_COUNTS|ok|apk|5|null|null|false'

if run_bad_wrapper "$WORK_DIR/apt.command" ||
   run_bad_wrapper "$WORK_DIR/rpm.command" ||
   run_bad_wrapper "$WORK_DIR/pkg.command"; then
  echo 'extra shell wrapper unexpectedly preserved the command result' >&2
  exit 1
fi

for forbidden in \
  'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" bash -c "$apt_count_command"' \
  'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" bash -c "$rpm_count_command"' \
  'RUN_SSH_COMMAND "$IP" "$SSH_VM_PORT" "$USER" sh -c "$package_count_command"'; do
  if grep -Fq "$forbidden" "$ROOT_DIR/check-updates.sh"; then
    echo "SSH count command still has an extra wrapper: $forbidden" >&2
    exit 1
  fi
done

printf '%s\n' 'VM SSH count command regression: PASS'
