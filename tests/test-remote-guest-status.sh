#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE="$ROOT_DIR/ultimate-updater"
WEB="$ROOT_DIR/web-ui/server.py"

# Remote guest checks must use the current central scripts and an isolated
# artifact directory, not an installed check-updates.sh on the remote node.
grep -Fq 'remote_check_dir="/tmp/ultimate-updater-check-target-' "$SOURCE"
grep -Fq 'bash -s -- %q %q' "$SOURCE"
grep -Fq 'INTERNAL_SSH_FILE=%q INTERNAL_SSH_CONFIG_FILE=%q' "$SOURCE"
if grep -Fq 'remote_check_script="/etc/ultimate-updater/check-updates.sh"' "$SOURCE"; then
    echo "remote guest checks must not use the installed check-updates.sh" >&2
    exit 1
fi

# Missing, empty and malformed status data must be classified without leaking
# a Python JSON traceback into the user-facing check output.
grep -Fq 'REMOTE_STATUS_MISSING' "$SOURCE"
grep -Fq 'REMOTE_STATUS_INVALID' "$SOURCE"
grep -Fq 'Remote guest status is invalid' "$SOURCE"
grep -Fq 'SSH_TRANSPORT' "$ROOT_DIR/check-updates.sh"
grep -Fq 'pct-config.error' "$ROOT_DIR/check-updates.sh"
grep -Fq 'target.get("error")' "$SOURCE"
# The source assertion intentionally matches shell parameter syntax literally.
# shellcheck disable=SC2016
grep -Fq 'STATUS_MODEL_IMPORT_FILE "${local_file}.filtered" 2>/dev/null' "$SOURCE"

# Internal SSH feedback and the edit/add distinction must remain explicit.
grep -Fq 'Connection successful.' "$WEB"
grep -Fq 'ssh-test-feedback' "$WEB"
grep -Fq 'Select target' "$WEB"
if grep -Fq 'Inventory target<select' "$WEB"; then
    echo "edit SSH UI must not expose the technical Inventory target label" >&2
    exit 1
fi
grep -Fq 'class="ssh-enabled-field"' "$WEB"
grep -Fq 'Unsupported API action.' "$WEB"

echo "remote guest status and Internal SSH UX tests: PASS"
