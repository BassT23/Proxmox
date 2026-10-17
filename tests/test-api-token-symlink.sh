#!/bin/sh
set -eu

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/uu-api-token.XXXXXX")
RECORD=$WORK_DIR/python-record
EXPECTED=$WORK_DIR/expected-record
STDERR_FILE=$WORK_DIR/stderr
ORIGINAL_PATH=${PATH-}

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

expect_record() {
    if ! cmp -s "$EXPECTED" "$RECORD"; then
        printf '%s\n' 'Expected Python invocation:' >&2
        sed 's/^/  /' "$EXPECTED" >&2
        printf '%s\n' 'Actual Python invocation:' >&2
        sed 's/^/  /' "$RECORD" >&2
        fail 'Python invocation did not match'
    fi
}

write_expected() {
    expected_script=$1
    shift
    {
        printf 'script=%s\n' "$expected_script"
        for argument do
            printf 'arg=%s\n' "$argument"
        done
    } > "$EXPECTED"
}

mkdir -p \
    "$WORK_DIR/install/web-ui" \
    "$WORK_DIR/bin" \
    "$WORK_DIR/tools" \
    "$WORK_DIR/path with spaces/install/web-ui" \
    "$WORK_DIR/path with spaces/bin"

cp "$TEST_ROOT/api-token.sh" "$WORK_DIR/install/api-token.sh"
printf '%s\n' '# isolated helper placeholder; the python3 shim handles execution' \
    > "$WORK_DIR/install/web-ui/api_tokens.py"
ln -s ../install/api-token.sh "$WORK_DIR/bin/ultimate-updater-api-token"

cat > "$WORK_DIR/tools/python3" <<'PYTHON_SHIM'
#!/bin/sh
set -eu

record=${UU_TOKEN_TEST_RECORD:?}
printf 'script=%s\n' "$1" > "$record"
shift
for argument do
    printf 'arg=%s\n' "$argument" >> "$record"
done
PYTHON_SHIM
chmod 755 "$WORK_DIR/tools/python3"

PATH="$WORK_DIR/tools:$ORIGINAL_PATH"
export PATH
export UU_TOKEN_TEST_RECORD="$RECORD"

: > "$RECORD"
write_expected \
    "$WORK_DIR/install/web-ui/api_tokens.py" \
    enable list 'argument with spaces' '--mode=isolated'
"$WORK_DIR/install/api-token.sh" \
    enable list 'argument with spaces' '--mode=isolated'
expect_record

: > "$RECORD"
write_expected \
    "$WORK_DIR/install/web-ui/api_tokens.py" \
    list '--from=absolute-symlink'
"$WORK_DIR/bin/ultimate-updater-api-token" \
    list '--from=absolute-symlink'
expect_record

: > "$RECORD"
write_expected \
    "$WORK_DIR/install/web-ui/api_tokens.py" \
    enable '--from=path'
(
    cd "$WORK_DIR"
    PATH="$WORK_DIR/tools:$WORK_DIR/bin:$ORIGINAL_PATH" \
        UU_TOKEN_TEST_RECORD=$RECORD \
        ultimate-updater-api-token enable '--from=path'
)
expect_record

: > "$RECORD"
write_expected \
    "$WORK_DIR/install/web-ui/api_tokens.py" \
    list '--from=relative'
(
    cd "$WORK_DIR"
    PATH="$WORK_DIR/tools:$ORIGINAL_PATH" \
        UU_TOKEN_TEST_RECORD=$RECORD \
        ./install/api-token.sh list '--from=relative'
)
expect_record

SPACE_INSTALL=$WORK_DIR/path\ with\ spaces/install
SPACE_SCRIPT=$SPACE_INSTALL/api-token.sh
SPACE_HELPER=$SPACE_INSTALL/web-ui/api_tokens.py
cp "$TEST_ROOT/api-token.sh" "$SPACE_SCRIPT"
printf '%s\n' '# isolated helper placeholder' > "$SPACE_HELPER"
ln -s ../install/api-token.sh \
    "$WORK_DIR/path with spaces/bin/ultimate-updater-api-token"

: > "$RECORD"
write_expected "$SPACE_HELPER" enable '--path=with spaces'
"$WORK_DIR/path with spaces/bin/ultimate-updater-api-token" \
    enable '--path=with spaces'
expect_record

rm "$WORK_DIR/install/web-ui/api_tokens.py"
: > "$RECORD"
if "$WORK_DIR/install/api-token.sh" enable 2> "$STDERR_FILE"; then
    fail 'missing api_tokens.py unexpectedly succeeded'
fi
if [ -s "$RECORD" ]; then
    fail 'missing api_tokens.py invoked python3'
fi
if ! grep -F 'helper not found' "$STDERR_FILE" >/dev/null; then
    fail 'missing api_tokens.py error was not reported'
fi

ln -s "$WORK_DIR/missing/api-token.sh" "$WORK_DIR/bin/broken-api-token"
: > "$RECORD"
if "$WORK_DIR/bin/broken-api-token" list 2> "$STDERR_FILE"; then
    fail 'broken symlink unexpectedly succeeded'
fi
if [ -s "$RECORD" ]; then
    fail 'broken symlink invoked python3'
fi
if [ ! -s "$STDERR_FILE" ]; then
    fail 'broken symlink produced no diagnostic'
fi

printf '%s\n' 'PASS: API token wrapper resolves direct, relative, PATH, and symlink invocations safely'
