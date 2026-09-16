#!/bin/sh

# Emit a stable total-only package count for the supported non-APT Unix
# package managers.  Each command is invoked in its script-oriented quiet
# mode; no human-readable output is used as a status protocol.

set -u

manager=${1:-}
case "$manager" in
  pacman)
    command='pacman -Qu --quiet'
    ;;
  apk)
    command='apk list --upgradable --quiet'
    ;;
  pkg)
    command="pkg version -U -l '<' -q"
    ;;
  *)
    printf 'UU_PACKAGE_COUNTS|unknown|%s|unknown|null|null|false\n' "$manager"
    exit 2
    ;;
esac

if ! output=$(sh -c "$command" 2>/dev/null); then
  printf 'UU_PACKAGE_COUNTS|unknown|%s|unknown|null|null|false\n' "$manager"
  exit 2
fi

count=0
while IFS= read -r package; do
  [ -n "$package" ] || continue
  case "$package" in
    *[[:space:]]*)
      printf 'UU_PACKAGE_COUNTS|unknown|%s|unknown|null|null|false\n' "$manager"
      exit 2
      ;;
  esac
  count=$((count + 1))
done <<EOF
$output
EOF

# These backends do not provide a portable structured security-advisory split
# through this query.  Keep both sub-counts unknown rather than guessing.
printf 'UU_PACKAGE_COUNTS|ok|%s|%s|null|null|false\n' "$manager" "$count"
