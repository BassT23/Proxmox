#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/ultimate-updater"

# A single target check must not send a summary mail. Its result is imported
# into the central status model; notification dispatch belongs to the global
# check path or an explicit notification test. Keep these assertions focused
# on the execution contract rather than the complete shell formatting.
grep -Eq 'UU_DEFER_NOTIFICATION=true .*STATUS_MODEL_PARTIAL=true .*"\$CHECK_SCRIPT" chost' "$CLI"
grep -Eq 'UU_DEFER_NOTIFICATION=true .*STATUS_MODEL_PARTIAL=true .*"\$CHECK_SCRIPT" ccontainer "\$target"' "$CLI"
# Explicit VM checks opt into the lifecycle path even when the VM is already
# running. This marker is part of the single-check contract, not a notification
# side effect.
grep -Eq 'UU_DEFER_NOTIFICATION=true .*UU_EXPLICIT_TARGET_CHECK=true .*STATUS_MODEL_PARTIAL=true .*"\$CHECK_SCRIPT" cvm "\$target"' "$CLI"
grep -Eq 'UU_DEFER_NOTIFICATION=true .*UU_CHECK_SCOPE=host .*STATUS_MODEL_PARTIAL=true .*"\$CHECK_SCRIPT" node-host' "$CLI"

# Keep the global check notification path intact.
grep -Fq "STATUS_MODEL_SEND_NOTIFICATION \"\$STATUS_FILE\" \"\$LOCAL_FILES/update.conf\"" "$CLI"

echo 'single-target notification regression: PASS'
