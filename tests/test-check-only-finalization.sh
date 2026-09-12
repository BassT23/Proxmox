#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

make_fixture() {
  local check_rc=$1
  mkdir -p "$WORK_DIR/local/exit" "$WORK_DIR/local/update" "$WORK_DIR/state"
  printf '#!/usr/bin/env bash\nprintf "CHECK_MARKER\\n"\nexit %s\n' "$check_rc" > "$WORK_DIR/local/check-updates.sh"
  printf '#!/usr/bin/env bash\nprintf "PASSED_MARKER\\n" > "$UU_TEST_WORK/passed.marker"\n' > "$WORK_DIR/local/exit/passed.sh"
  printf '#!/usr/bin/env bash\nprintf "ERROR_MARKER\\n" > "$UU_TEST_WORK/error.marker"\n' > "$WORK_DIR/local/exit/error.sh"
  cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
printf 'UPDATE_MAIL_MARKER\n' > "$UU_TEST_WORK/update-mail.marker"
cat >/dev/null
EOF
  chmod +x "$WORK_DIR/local/check-updates.sh" "$WORK_DIR/local/exit"/*.sh "$WORK_DIR/mail"
  : > "$WORK_DIR/local/update.log"
  : > "$WORK_DIR/local/errors.log"
}

make_harness() {
  local harness=$1
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'LOCAL_FILES="$UU_TEST_WORK/local"\nTEMP_STATE_DIR="$UU_TEST_WORK/state"\n'
    printf 'TEMP_FOLDER="$UU_TEST_WORK/temp"\nLOG_FILE="$UU_TEST_WORK/local/update.log"\n'
    printf 'ERROR_LOG_FILE="$UU_TEST_WORK/local/errors.log"\nHOSTNAME=fixture\n'
    printf 'RICM=false WELCOME_SCREEN=false INITIAL_INVENTORY_CLI=false EXEC_HOST=""\n'
    printf 'SELF_UPDATE_RUN=false UU_DEFER_UPDATE_MAIL=false EMAIL_ONLY_ERROR=false\n'
    printf 'EMAIL_USER=fixture EMAIL_SENDER=fixture\nUPDATE_FAILURE=false SAFETY_FAILURE=false\n'
    printf 'CLEAN_LOGFILE() { :; }\nUPDATE_MAIL_BODY() { printf update-body; }\nsleep() { :; }\n'
    awk '/^EXIT \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$ROOT_DIR/update.sh"
  } > "$harness"
  chmod +x "$harness"
}

run_check_case() {
  local name=$1 check_rc=$2 expected_rc=$3
  make_fixture "$check_rc"
  local harness="$WORK_DIR/$name.sh"
  make_harness "$harness"
  awk '/^ARGUMENTS \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$ROOT_DIR/update.sh" >> "$harness"
  cat >> "$harness" <<'EOF'
CHECK_ONLY_RUN=false
trap EXIT EXIT
ARGUMENTS -check
EOF
  set +e
  UU_TEST_WORK="$WORK_DIR" PATH="$WORK_DIR:$PATH" bash "$harness" >"$WORK_DIR/$name.out" 2>&1
  local actual_rc=$?
  set -e
  [[ "$actual_rc" -eq "$expected_rc" ]]
  grep -Fq 'CHECK_MARKER' "$WORK_DIR/$name.out"
  [[ ! -e "$WORK_DIR/passed.marker" ]]
  [[ ! -e "$WORK_DIR/error.marker" ]]
  [[ ! -e "$WORK_DIR/update-mail.marker" ]]
  [[ ! -d "$WORK_DIR/local/update" ]]
}

run_check_case success 0 0
run_check_case failure 7 7
RUN_FROM_CRON=true run_check_case scheduled 0 0

make_fixture 0
normal_harness="$WORK_DIR/normal-update.sh"
make_harness "$normal_harness"
cat >> "$normal_harness" <<'EOF'
CHECK_ONLY_RUN=false
trap EXIT EXIT
exit 0
EOF
set +e
UU_TEST_WORK="$WORK_DIR" PATH="$WORK_DIR:$PATH" bash "$normal_harness" >"$WORK_DIR/normal.out" 2>&1
normal_rc=$?
set -e
[[ "$normal_rc" -eq 0 ]]
[[ -e "$WORK_DIR/passed.marker" ]]
[[ -e "$WORK_DIR/update-mail.marker" ]]

make_fixture 0
failed_update_harness="$WORK_DIR/failed-update.sh"
make_harness "$failed_update_harness"
cat >> "$failed_update_harness" <<'EOF'
CHECK_ONLY_RUN=false
trap EXIT EXIT
exit 7
EOF
set +e
UU_TEST_WORK="$WORK_DIR" PATH="$WORK_DIR:$PATH" bash "$failed_update_harness" >"$WORK_DIR/failed-update.out" 2>&1
failed_update_rc=$?
set -e
[[ "$failed_update_rc" -eq 7 ]]
[[ -e "$WORK_DIR/error.marker" ]]
[[ -e "$WORK_DIR/update-mail.marker" ]]

echo 'check-only finalization tests: PASS'
