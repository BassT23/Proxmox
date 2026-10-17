#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SCRIPT_DIR/web-ui/api_tokens.py" "$@"
