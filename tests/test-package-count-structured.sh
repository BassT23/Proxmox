#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/bin"

for manager in pacman apk pkg; do
  cat > "$WORK_DIR/bin/$manager" <<'SH'
#!/bin/sh
case "${PACKAGE_FIXTURE:-mixed}" in
  zero) exit 0 ;;
  mixed) printf 'pkg-one\npkg-two\n'; exit 0 ;;
  malformed) printf 'localized package-manager warning\n'; exit 0 ;;
  error) exit 7 ;;
esac
SH
  chmod 755 "$WORK_DIR/bin/$manager"
done

for manager in pacman apk pkg; do
  expected="UU_PACKAGE_COUNTS|ok|$manager|2|null|null|false"
  actual=$(PATH="$WORK_DIR/bin:/usr/bin:/bin" PACKAGE_FIXTURE=mixed \
    "$ROOT_DIR/package-count.sh" "$manager")
  [[ "$actual" == "$expected" ]]
  [[ "$(PATH="$WORK_DIR/bin:/usr/bin:/bin" PACKAGE_FIXTURE=zero \
    "$ROOT_DIR/package-count.sh" "$manager")" == "UU_PACKAGE_COUNTS|ok|$manager|0|null|null|false" ]]
  if PATH="$WORK_DIR/bin:/usr/bin:/bin" PACKAGE_FIXTURE=malformed \
    "$ROOT_DIR/package-count.sh" "$manager" >/dev/null; then
    echo "$manager accepted malformed package metadata" >&2
    exit 1
  fi
  if PATH="$WORK_DIR/bin:/usr/bin:/bin" PACKAGE_FIXTURE=error \
    "$ROOT_DIR/package-count.sh" "$manager" >/dev/null; then
    echo "$manager accepted a query failure" >&2
    exit 1
  fi
  for locale in C en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8; do
    localized=$(env -u LC_ALL LANG="$locale" LC_MESSAGES="$locale" \
      PATH="$WORK_DIR/bin:/usr/bin:/bin" PACKAGE_FIXTURE=mixed \
      "$ROOT_DIR/package-count.sh" "$manager")
    [[ "$localized" == "$expected" ]]
  done
done

if "$ROOT_DIR/package-count.sh" unsupported >/dev/null; then
  echo 'unsupported package manager was accepted' >&2
  exit 1
fi

echo 'structured package count tests: PASS'
