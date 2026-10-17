#!/bin/sh
set -eu

case $0 in
    */*) SCRIPT_ENTRY=$0 ;;
    *)
        SCRIPT_ENTRY=$(command -v "$0" 2>/dev/null) || SCRIPT_ENTRY=$0
        ;;
esac

SCRIPT_PATH=$(readlink -f -- "$SCRIPT_ENTRY") || {
    printf '%s\n' 'api-token: unable to resolve the wrapper path' >&2
    exit 1
}

SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
PYTHON_SCRIPT=$SCRIPT_DIR/web-ui/api_tokens.py

if [ ! -f "$PYTHON_SCRIPT" ]; then
    printf 'api-token: helper not found: %s\n' "$PYTHON_SCRIPT" >&2
    exit 1
fi

exec python3 "$PYTHON_SCRIPT" "$@"
