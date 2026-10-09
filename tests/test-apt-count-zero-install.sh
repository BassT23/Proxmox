#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/apt-get" <<'SH'
#!/bin/sh
case "${APT_FIXTURE:-mixed}" in
  mixed)
    printf '%s\n' \
      'Reading package lists...' \
      'Inst openssl [old] (new Debian:12.12/stable-security [amd64])' \
      'Inst curl [old] (new Debian:12.12/stable [amd64])' \
      '0 upgraded, 2 newly installed, 0 to remove and 0 not upgraded.'
    ;;
  zero)
    printf '%s\n' '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.'
    ;;
  malformed)
    printf '%s\n' 'Inst malformed output'
    ;;
  error)
    exit 100
    ;;
esac
SH
chmod 750 "$WORK_DIR/apt-get"

cat > "$WORK_DIR/python3" <<'SH'
#!/bin/sh
# Simulate either no python-apt or a working structured runtime.
if [ "${PYTHON_APT_FIXTURE:-missing}" = available ]; then
  case "${1:-}" in
    -c) exit 0 ;;
    *) printf '%s\n' 'APT_COUNTS|7|5|2|true' ; exit 0 ;;
  esac
fi
exit 1
SH
chmod 750 "$WORK_DIR/python3"

fallback_env=(PATH="$WORK_DIR:/usr/bin:/bin" APT_FIXTURE=mixed PYTHON_APT_FIXTURE=missing)
fallback=$(env "${fallback_env[@]}" "$ROOT_DIR/apt-count.sh")
[[ "$fallback" == 'APT_COUNTS|2|1|1|true' ]]

zero=$(env PATH="$WORK_DIR:/usr/bin:/bin" APT_FIXTURE=zero \
  PYTHON_APT_FIXTURE=missing "$ROOT_DIR/apt-count.sh")
[[ "$zero" == 'APT_COUNTS|0|0|0|true' ]]

if env PATH="$WORK_DIR:/usr/bin:/bin" APT_FIXTURE=malformed \
  PYTHON_APT_FIXTURE=missing "$ROOT_DIR/apt-count.sh" >/dev/null 2>&1; then
  echo 'malformed apt simulation was accepted' >&2
  exit 1
fi

if env PATH="$WORK_DIR:/usr/bin:/bin" APT_FIXTURE=error \
  PYTHON_APT_FIXTURE=missing "$ROOT_DIR/apt-count.sh" >/dev/null 2>&1; then
  echo 'apt simulation failure was accepted' >&2
  exit 1
fi

structured=$(env PATH="$WORK_DIR:/usr/bin:/bin" APT_FIXTURE=zero \
  PYTHON_APT_FIXTURE=available APT_COUNT_PYTHON_SCRIPT="$ROOT_DIR/apt-count.py" \
  "$ROOT_DIR/apt-count.sh")
[[ "$structured" == 'APT_COUNTS|7|5|2|true' ]]

printf '%s\n' 'APT zero-install count tests: PASS'
