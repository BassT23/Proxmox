#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

awk '/^CLASSIFY_SSH_EXIT\(\) \{/{copy=1} copy{print} copy && /^}/{exit}' \
  "$ROOT_DIR/target-runtime.sh" > "$WORK_DIR/classifier.sh"
# shellcheck disable=SC1091 # the classifier is the test's extracted fixture.
source "$WORK_DIR/classifier.sh"

[[ "$(CLASSIFY_SSH_EXIT 0)" == SSH_OK ]]
[[ "$(CLASSIFY_SSH_EXIT 124)" == SSH_TIMEOUT ]]
[[ "$(CLASSIFY_SSH_EXIT 255)" == SSH_CONNECTION_FAILED ]]
[[ "$(CLASSIFY_SSH_EXIT 1)" == REMOTE_COMMAND_FAILED ]]
[[ "$(CLASSIFY_SSH_EXIT 42)" == REMOTE_COMMAND_FAILED ]]

for diagnostic in \
  'Permission denied (publickey)' \
  'Verbindung abgelehnt' \
  'Connexion refusée' \
  'random transport diagnostic'; do
  [[ -n "$diagnostic" ]]
  [[ "$(CLASSIFY_SSH_EXIT 255)" == SSH_CONNECTION_FAILED ]] || exit 1
done

echo 'SSH transport classification tests: PASS'
