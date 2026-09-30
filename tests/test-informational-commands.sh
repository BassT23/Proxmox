#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

make_harness() {
  local harness=$1
  mkdir -p "$WORK_DIR/local/exit" "$WORK_DIR/state"
  cat > "$WORK_DIR/mail" <<'EOF'
#!/usr/bin/env bash
printf 'MAIL_SENT\n' > "$UU_TEST_WORK/mail.marker"
cat >/dev/null
EOF
  cat > "$WORK_DIR/local/exit/passed.sh" <<'EOF'
#!/usr/bin/env bash
printf 'PASSED\n' > "$UU_TEST_WORK/passed.marker"
EOF
  cat > "$WORK_DIR/local/exit/error.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ERROR\n' > "$UU_TEST_WORK/error.marker"
EOF
  chmod +x "$WORK_DIR/mail" "$WORK_DIR/local/exit"/*.sh
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'LOCAL_FILES="$UU_TEST_WORK/local"\nTEMP_STATE_DIR="$UU_TEST_WORK/state"\n'
    printf 'TEMP_FOLDER="$UU_TEST_WORK/temp"\nLOG_FILE="$UU_TEST_WORK/update.log"\nERROR_LOG_FILE="$UU_TEST_WORK/errors.log"\n'
    printf 'HOSTNAME=fixture RICM=false WELCOME_SCREEN=false INITIAL_INVENTORY_CLI=false EXEC_HOST=""\n'
    printf 'SELF_UPDATE_RUN=false UU_DEFER_UPDATE_MAIL=false EMAIL_ONLY_ERROR=false\n'
    printf 'EMAIL_USER=fixture EMAIL_SENDER=fixture NON_UPDATE_COMMAND=false\n'
    printf 'CLEAN_LOGFILE() { :; }\nUPDATE_MAIL_BODY() { printf update-body; }\nsleep() { :; }\n'
    printf "EFFECTIVE_HEADLESS() { return 1; }\nUSAGE() { printf 'HELP\\n'; }\nVERSION_CHECK() { printf 'VERSION\\n'; }\n"
    awk '/^EXIT \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$ROOT_DIR/update.sh"
    awk '/^ARGUMENTS \(\) \{/{copy=1} copy{print} copy && /^}/{exit}' "$ROOT_DIR/update.sh"
    printf 'trap EXIT EXIT\nARGUMENTS "$1"\n'
  } > "$harness"
  chmod +x "$harness"
}

for command in -h --help -v --version; do
  make_harness "$WORK_DIR/harness"
  set +e
  UU_TEST_WORK="$WORK_DIR" PATH="$WORK_DIR:$PATH" bash "$WORK_DIR/harness" "$command" >"$WORK_DIR/output" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || { echo "$command returned $rc" >&2; cat "$WORK_DIR/output" >&2; exit 1; }
  [[ ! -e "$WORK_DIR/mail.marker" ]]
  [[ ! -e "$WORK_DIR/passed.marker" ]]
  [[ ! -e "$WORK_DIR/error.marker" ]]
  rm -f "$WORK_DIR/mail.marker" "$WORK_DIR/passed.marker" "$WORK_DIR/error.marker"
done

echo 'informational command finalization tests: PASS'
