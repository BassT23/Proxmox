#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir "$WORK_DIR/bin"

cat > "$WORK_DIR/bin/dnf" <<'SH'
#!/bin/sh
case "${RPM_FIXTURE:-mixed}" in
  zero) exit 0 ;;
  mixed)
    printf 'bash\tx86_64\tfedora\nbash\tx86_64\tfedora\nopenssl\tx86_64\tupdates\n'
    exit 0
    ;;
  malformed) printf 'not-a-structured-record\n'; exit 0 ;;
  error) exit 7 ;;
esac
SH
chmod 755 "$WORK_DIR/bin/dnf"

# The fake emits the helper's requested tabular format; no human-readable DNF
# output is involved in the count contract.
expected='UU_RPM_COUNTS|ok|2|null|null|false'
[[ "$(PATH="$WORK_DIR/bin:/usr/bin:/bin" RPM_FIXTURE=mixed python3 "$ROOT_DIR/rpm-count.py")" == "$expected" ]]
[[ "$(PATH="$WORK_DIR/bin:/usr/bin:/bin" RPM_FIXTURE=zero python3 "$ROOT_DIR/rpm-count.py")" == 'UU_RPM_COUNTS|ok|0|null|null|false' ]]
if PATH="$WORK_DIR/bin:/usr/bin:/bin" RPM_FIXTURE=malformed python3 "$ROOT_DIR/rpm-count.py" >/dev/null; then
  echo 'malformed RPM metadata was accepted' >&2
  exit 1
fi
if PATH="$WORK_DIR/bin:/usr/bin:/bin" RPM_FIXTURE=error python3 "$ROOT_DIR/rpm-count.py" >/dev/null; then
  echo 'RPM query failure was accepted' >&2
  exit 1
fi
for locale in C en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8; do
  [[ "$(env -u LC_ALL LANG="$locale" LC_MESSAGES="$locale" PATH="$WORK_DIR/bin:/usr/bin:/bin" RPM_FIXTURE=mixed python3 "$ROOT_DIR/rpm-count.py")" == "$expected" ]]
done

echo 'structured RPM count tests: PASS'
