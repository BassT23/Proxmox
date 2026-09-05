#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

bash -n "$ROOT_DIR/external-helper.sh" "$ROOT_DIR/external-bootstrap.sh"
shellcheck "$ROOT_DIR/external-helper.sh" "$ROOT_DIR/external-bootstrap.sh"

version=$("$ROOT_DIR/external-helper.sh" version)
[[ "$version" == 'ultimate-updater-external 1' ]]

if [ "$(id -u)" -ne 0 ]; then
  if "$ROOT_DIR/external-helper.sh" update >/dev/null 2>&1; then
    echo 'external helper unexpectedly allowed non-root update' >&2
    exit 1
  fi
fi
if "$ROOT_DIR/external-helper.sh" update extra >/dev/null 2>&1; then
  echo 'external helper unexpectedly accepted extra arguments' >&2
  exit 1
fi
if "$ROOT_DIR/external-helper.sh" shell >/dev/null 2>&1; then
  echo 'external helper unexpectedly accepted arbitrary action' >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])(eval|source)([[:space:]]|$)' "$ROOT_DIR/external-helper.sh"; then
  echo 'external helper contains unsafe source/eval' >&2
  exit 1
fi
if grep -Eq '\$[@*]' "$ROOT_DIR/external-helper.sh"; then
  echo 'external helper forwards arbitrary arguments' >&2
  exit 1
fi
echo 'external helper validation tests: PASS'
