#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UPDATE_SH="$ROOT_DIR/update.sh"

# Remote cluster updates must pull check-output from the remote node after the
# remote run instead of depending on reverse SSH from that node.
grep -Fq \
  'scp "$HOST:$LOCAL_FILES/check-output" "$LOCAL_FILES/check-output"' \
  "$UPDATE_SH"

# EXIT must never attempt an SCP to the local host itself.
grep -Fq \
  '"$HOSTNAME" != "$EXEC_HOST"' \
  "$UPDATE_SH"

# The old unconditional reverse-copy condition must be gone.
if grep -Fq \
  'if [[ "$WELCOME_SCREEN" == true && -n "$EXEC_HOST" ]]; then' \
  "$UPDATE_SH"; then
  echo "Unconditional reverse check-output SCP is still present" >&2
  exit 1
fi

echo "Cluster check-output transfer regression tests: PASS"
