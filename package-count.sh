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

if [ "$manager" = pkg ]; then
  # FreeBSD pkg prints the package name and the '<' marker as two columns.
  # Whitespace between those columns is part of the normal output format,
  # unlike the one-entry-per-line output used by pacman and apk.
  if ! count=$(printf '%s\n' "$output" | awk '
    BEGIN { valid = 1; count = 0 }
    NF {
      if (NF != 2 || $2 != "<")
        valid = 0
      else
        count++
    }
    END {
      if (!valid)
        exit 1
      print count
    }
  '); then
    printf 'UU_PACKAGE_COUNTS|unknown|%s|unknown|null|null|false\n' "$manager"
    exit 2
  fi
  printf 'UU_PACKAGE_COUNTS|ok|%s|%s|null|null|false\n' "$manager" "$count"
  exit 0
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
