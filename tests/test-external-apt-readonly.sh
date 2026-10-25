#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete; rmdir "$WORK_DIR/fake-bin" "$WORK_DIR" 2>/dev/null || true' EXIT
mkdir "$WORK_DIR/fake-bin"
cat > "$WORK_DIR/apt-count.py" <<'PY'
import os
import sys

if os.environ.get("APT_COUNT_LOG"):
    with open(os.environ["APT_COUNT_LOG"], "a", encoding="utf-8") as log:
        log.write("count\n")

if os.environ.get("APT_MODE") == "error":
    print("APT_COUNTS|unknown|unknown|unknown|false")
    sys.exit(2)
print("APT_COUNTS|1|1|0|true" if os.environ.get("APT_MODE") == "updates" else "APT_COUNTS|0|0|0|true")
PY
cat > "$WORK_DIR/rpm-count.py" <<'PY'
import os

if os.environ.get("RPM_MODE") == "zero":
  print("UU_RPM_COUNTS|ok|0|null|null|false")
else:
  print("UU_RPM_COUNTS|ok|2|null|null|false")
PY

cat > "$WORK_DIR/fake-bin/ssh" <<'FAKE_SSH'
#!/bin/bash
printf '%s\n' "$*" > "${SSH_ARGS_LOG:?}"
case "$*" in
  *timeout-target*) sleep 3; exit 0 ;;
esac
script=$(cat)
if [[ -n "${REMOTE_CONFIG:-}" ]]; then
  script=${script//config=\/etc\/ultimate-updater\/external.conf/config=$REMOTE_CONFIG}
fi
if [[ -n "${REMOTE_OS_RELEASE:-}" ]]; then
  script=$(printf '%s\n' "$script" | sed "s#\. /etc/os-release#. \"$REMOTE_OS_RELEASE\"#")
fi
remote_command="${@: -1}"
bash -c "$remote_command" <<< "$script"
FAKE_SSH

cat > "$WORK_DIR/fake-bin/apt" <<'FAKE_APT'
#!/bin/bash
exit 0
FAKE_APT

cat > "$WORK_DIR/fake-bin/apt-get" <<'FAKE_APT_GET'
#!/bin/bash
if [[ "${1:-}" == update ]]; then
  printf 'refresh\n' >> "${APT_REFRESH_LOG:?}"
  [[ "${APT_REFRESH_FAIL:-false}" == true ]] && exit 99
  exit 0
fi
if [[ "${APT_MODE:-updates}" == error ]]; then exit 7; fi
if [[ "${APT_MODE:-updates}" == updates ]]; then
  printf 'Inst fixture (1.0) [1.0]\n'
fi
exit 0
FAKE_APT_GET
cat > "$WORK_DIR/fake-bin/id" <<'FAKE_ID'
#!/bin/bash
if [[ "${1:-}" == -u ]]; then printf '0\n'; else /usr/bin/id "$@"; fi
FAKE_ID
cat > "$WORK_DIR/fake-bin/sudo" <<'FAKE_SUDO'
#!/bin/bash
printf 'sudo:%s\n' "$*" >> "${SUDO_LOG:?}"
[[ "${SUDO_REFRESH_FAIL:-false}" != true ]] || exit 1
[[ "${1:-}" == -n ]] && shift
exec "$@"
FAKE_SUDO
cat > "$WORK_DIR/fake-bin/stat" <<'FAKE_STAT'
#!/bin/bash
if [[ "${1:-}" == -c && "${2:-}" == '%u %a' ]]; then
  printf '0 755\n'
else
  exec /usr/bin/stat "$@"
fi
FAKE_STAT
chmod 755 "$WORK_DIR/fake-bin"/*
cat > "$WORK_DIR/debian-os-release" <<'OS_RELEASE'
ID=debian
ID_LIKE=debian
PRETTY_NAME="Debian fixture"
VERSION_ID="13"
OS_RELEASE
cat > "$WORK_DIR/fedora-os-release" <<'OS_RELEASE'
ID=fedora
ID_LIKE=""
PRETTY_NAME="Fedora fixture"
VERSION_ID="40"
OS_RELEASE
cat > "$WORK_DIR/fake-bin/dnf" <<'FAKE_DNF'
#!/bin/bash
exit 0
FAKE_DNF
chmod 755 "$WORK_DIR/fake-bin/dnf"
touch "$WORK_DIR/identity"

grep -Fq 'UU_APT_COUNT_COMMAND' "$ROOT_DIR/external-apt.sh"
grep -Fq 'apt-get update -y >/dev/null 2>&1' "$ROOT_DIR/target-runtime.sh"
awk '/update_apt\(\)/{update=1} update && /apt-get update/{found=1} END{exit(found ? 0 : 1)}' \
  "$ROOT_DIR/external-helper.sh"

cat > "$WORK_DIR/targets.conf" <<CONFIG
[updates]
host=updates-target
transport=ssh
user=root
port=22
[zero]
host=zero-target
transport=ssh
user=root
port=22
[error]
host=error-target
transport=ssh
user=root
port=22
[timeout]
host=timeout-target
transport=ssh
user=root
port=22
identity_file=$WORK_DIR/identity
[refresh-fail]
host=refresh-fail-target
transport=ssh
user=root
port=22
[nonroot]
host=nonroot-target
transport=ssh
user=basst
port=22
[dnf]
host=dnf-target
transport=ssh
user=root
port=22
CONFIG

run_check() {
  local target=$1 mode=$2 expected_rc=$3 expected_state=$4 rpm_mode=${5:-updates} refresh_fail=${6:-false} sudo_fail=${7:-false}
  local status_file="$WORK_DIR/$target-status.json"
  local remote_os_release="$WORK_DIR/debian-os-release"
  [[ "$target" == dnf ]] && remote_os_release="$WORK_DIR/fedora-os-release"
  printf '{"%s":{"generation":0,"active":false,"operation_id":""}}\n' "$target" > "$WORK_DIR/$target-generation.json"
  APT_MODE="$mode" RPM_MODE="$rpm_mode" APT_REFRESH_FAIL="$refresh_fail" SUDO_REFRESH_FAIL="$sudo_fail" \
    APT_REFRESH_LOG="$WORK_DIR/$target-refresh.log" MUTATION_MARKER="$WORK_DIR/mutation" \
    APT_COUNT_LOG="$WORK_DIR/$target-count.log" \
    HELPER_REFRESH_LOG="$WORK_DIR/$target-helper-refresh.log" \
    HELPER_LOG="$WORK_DIR/$target-helper.log" SUDO_LOG="$WORK_DIR/$target-sudo.log" \
    UU_REBOOT_REQUIRED_FILE="$WORK_DIR/no-reboot-required" \
    UU_REBOOT_REQUIRED_PACKAGES_FILE="$WORK_DIR/no-reboot-required.pkgs" \
    REMOTE_CONFIG="$WORK_DIR/external.conf" \
    PATH="$WORK_DIR/fake-bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
    TARGET_INVENTORY_FILE="$WORK_DIR/targets.conf" \
    TARGET_INVENTORY_SCRIPT="$ROOT_DIR/target-inventory.sh" \
    STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh" TARGET_RUNTIME_SCRIPT="$ROOT_DIR/target-runtime.sh" \
    STATUS_MODEL_FILE="$status_file" STATUS_MODEL_RECORD_FILE="$WORK_DIR/$target-records" \
    STATUS_MODEL_GENERATION_FILE="$WORK_DIR/$target-generation.json" \
    RPM_COUNT_SCRIPT="$WORK_DIR/rpm-count.py" \
    EXTERNAL_HELPER_PATH="$WORK_DIR/helper" \
    REMOTE_OS_RELEASE="$remote_os_release" \
    SSH_ARGS_LOG="$WORK_DIR/$target-ssh.args" UU_SSH_COMMAND_TIMEOUT=1 "$ROOT_DIR/external-apt.sh" check "$target" > "$WORK_DIR/$target.out" 2>&1 || rc=$?
  rc=${rc:-0}
  if [[ "$rc" -ne "$expected_rc" ]]; then
    cat "$WORK_DIR/$target.out" >&2
    cat "$WORK_DIR/$target-sudo.log" "$WORK_DIR/$target-helper.log" 2>/dev/null >&2 || true
  fi
  [[ "$rc" -eq "$expected_rc" ]]
  grep -Fq '"check_status": "'"$expected_state"'"' "$status_file"
  unset rc
}

cat > "$WORK_DIR/external.conf" <<'CONFIG'
schema_version="1"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK=""
ONLY=""
EXCLUDE=""
CONFIG

cat > "$WORK_DIR/helper" <<'HELPER'
#!/bin/bash
printf 'helper:%s\n' "$*" >> "${HELPER_LOG:?}"
case "${1:-}" in
  version) printf 'ultimate-updater-external 1\n' ;;
  apt-refresh)
    printf 'refresh\n' >> "${HELPER_REFRESH_LOG:?}"
    [[ "${HELPER_REFRESH_FAIL:-false}" == true ]] && exit 99
    exit 0
    ;;
  *) exit 64 ;;
esac
HELPER
chmod 755 "$WORK_DIR/helper"

run_check updates updates 0 updates_available
[[ -s "$WORK_DIR/updates-refresh.log" ]]
python3 - "$WORK_DIR/updates-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] == 1
assert target["normal_updates"] == 1
assert target["security_updates"] == 0
assert target["security_split_supported"] is True
PY
run_check zero zero 0 ok
python3 - "$WORK_DIR/zero-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] == 0
assert target["normal_updates"] == 0
assert target["security_updates"] == 0
assert target["security_split_supported"] is True
assert target["packages"] == []
PY
run_check error error 1 error
run_check refresh-fail updates 1 error updates true
python3 - "$WORK_DIR/refresh-fail-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] is None
assert target["error"]["code"] == "APT_CHECK_FAILED"
PY
run_check timeout updates 1 offline
[[ ! -e "$WORK_DIR/mutation" ]]
grep -Fq -- "-i $WORK_DIR/identity" "$WORK_DIR/timeout-ssh.args"

# A non-root External check uses only the fixed helper refresh action.  The
# count command itself must not run apt-get update a second time.
cat > "$WORK_DIR/fake-bin/id" <<'FAKE_NONROOT_ID'
#!/bin/bash
if [[ "${1:-}" == -u ]]; then printf '1000\n'; else /usr/bin/id "$@"; fi
FAKE_NONROOT_ID
chmod 755 "$WORK_DIR/fake-bin/id"
run_check nonroot updates 0 updates_available
[[ ! -s "$WORK_DIR/nonroot-refresh.log" ]]
[[ -s "$WORK_DIR/nonroot-helper-refresh.log" ]]

# Without the authorized helper refresh, the check fails closed before the
# structured count and never reports a cached or synthetic zero.
: > "$WORK_DIR/nonroot-count.log"
run_check nonroot updates 1 error updates false true
python3 - "$WORK_DIR/nonroot-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] is None, target
assert target["error"]["code"] == "APT_REFRESH_PRIVILEGE_REQUIRED", target
assert not open(sys.argv[1].replace("-status.json", "-count.log"), encoding="utf-8").read(), target
PY

cat > "$WORK_DIR/external.conf" <<'CONFIG'
schema_version="1"
UNKNOWN_KEY="must be rejected"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK=""
ONLY=""
EXCLUDE=""
CONFIG
run_check nonroot updates 1 error

cat > "$WORK_DIR/external.conf" <<'CONFIG'
schema_version="1"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK=""
ONLY=""
EXCLUDE=""
CONFIG
run_check dnf updates 0 updates_available
python3 - "$WORK_DIR/dnf-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] == 2
assert target["normal_updates"] is None
assert target["security_updates"] is None
assert target["security_split_supported"] is False
assert target["packages"] is None
PY
run_check dnf zero 0 ok zero
python3 - "$WORK_DIR/dnf-status.json" <<'PY'
import json
import sys

target = json.load(open(sys.argv[1], encoding="utf-8"))["targets"][0]
assert target["updates"]["available"] == 0
assert target["packages"] == []
PY

echo 'external apt read-only tests: PASS'
