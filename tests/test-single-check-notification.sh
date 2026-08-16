#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CLI="$ROOT_DIR/ultimate-updater"

# A single target check must not send a summary mail.  Its result is imported
# into the central status model; notification dispatch belongs to the global
# check path or an explicit notification test.
grep -Fq "UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true \"\$CHECK_SCRIPT\" chost" "$CLI"
grep -Fq "UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true \"\$CHECK_SCRIPT\" ccontainer \"\$target\"" "$CLI"
grep -Fq "UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true \"\$CHECK_SCRIPT\" cvm \"\$target\"" "$CLI"
grep -Fq "UU_DEFER_NOTIFICATION=true STATUS_MODEL_PARTIAL=true \"\$CHECK_SCRIPT\" host" "$CLI"

# Keep the global check notification path intact.
grep -Fq "STATUS_MODEL_SEND_NOTIFICATION \"\$STATUS_FILE\" \"\$LOCAL_FILES/update.conf\"" "$CLI"

echo 'single-target notification regression: PASS'
