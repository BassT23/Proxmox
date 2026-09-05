#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'find "$WORK_DIR" -type f -delete; rmdir "$WORK_DIR/fake-bin" "$WORK_DIR" 2>/dev/null || true' EXIT
mkdir "$WORK_DIR/fake-bin"

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
bash -s <<< "$script"
FAKE_SSH

cat > "$WORK_DIR/fake-bin/apt" <<'FAKE_APT'
#!/bin/bash
exit 0
FAKE_APT

cat > "$WORK_DIR/fake-bin/apt-get" <<'FAKE_APT_GET'
#!/bin/bash
if [[ "${1:-}" == update ]]; then
  : > "${MUTATION_MARKER:?}"
  exit 99
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
chmod 755 "$WORK_DIR/fake-bin"/*
touch "$WORK_DIR/identity"

awk '/<<.*REMOTE_CHECK/{check=1; next} /<<.*REMOTE_UPDATE/{check=0} check && /apt-get update/{found=1} END{exit(found ? 1 : 0)}' \
  "$ROOT_DIR/external-apt.sh"
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
[nonroot]
host=nonroot-target
transport=ssh
user=basst
port=22
CONFIG

run_check() {
  local target=$1 mode=$2 expected_rc=$3 expected_state=$4
  local status_file="$WORK_DIR/$target-status.json"
  APT_MODE="$mode" MUTATION_MARKER="$WORK_DIR/mutation" \
    UU_REBOOT_REQUIRED_FILE="$WORK_DIR/no-reboot-required" \
    UU_REBOOT_REQUIRED_PACKAGES_FILE="$WORK_DIR/no-reboot-required.pkgs" \
    REMOTE_CONFIG="$WORK_DIR/external.conf" \
    PATH="$WORK_DIR/fake-bin:$PATH" UU_LOCAL_FILES="$WORK_DIR" \
    TARGET_INVENTORY_FILE="$WORK_DIR/targets.conf" \
    TARGET_INVENTORY_SCRIPT="$ROOT_DIR/target-inventory.sh" \
    STATUS_MODEL_SCRIPT="$ROOT_DIR/status-model.sh" TARGET_RUNTIME_SCRIPT="$ROOT_DIR/target-runtime.sh" \
    STATUS_MODEL_FILE="$status_file" STATUS_MODEL_RECORD_FILE="$WORK_DIR/$target-records" \
    SSH_ARGS_LOG="$WORK_DIR/$target-ssh.args" UU_SSH_COMMAND_TIMEOUT=1 "$ROOT_DIR/external-apt.sh" check "$target" > "$WORK_DIR/$target.out" 2>&1 || rc=$?
  rc=${rc:-0}
  if [[ "$rc" -ne "$expected_rc" ]]; then
    cat "$WORK_DIR/$target.out" >&2
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

run_check updates updates 0 updates_available
grep -Fq '"available": 1' "$WORK_DIR/updates-status.json"
run_check zero zero 0 ok
grep -Fq '"available": 0' "$WORK_DIR/zero-status.json"
run_check error error 1 error
run_check timeout updates 1 offline
[[ ! -e "$WORK_DIR/mutation" ]]
grep -Fq -- "-i $WORK_DIR/identity" "$WORK_DIR/timeout-ssh.args"

# A normal external check must not require passwordless sudo.  The fake
# remote user is deliberately non-root while its read-only apt simulation
# remains available.
cat > "$WORK_DIR/fake-bin/id" <<'FAKE_NONROOT_ID'
#!/bin/bash
if [[ "${1:-}" == -u ]]; then printf '1000\n'; else /usr/bin/id "$@"; fi
FAKE_NONROOT_ID
chmod 755 "$WORK_DIR/fake-bin/id"
run_check nonroot updates 0 updates_available

cat > "$WORK_DIR/external.conf" <<'CONFIG'
schema_version="1"
UNKNOWN_KEY="must be rejected"
ONLY_UPDATE_CHECK=""
EXCLUDE_UPDATE_CHECK=""
ONLY=""
EXCLUDE=""
CONFIG
run_check nonroot updates 1 error

echo 'external apt read-only tests: PASS'
