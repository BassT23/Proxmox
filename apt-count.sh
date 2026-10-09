#!/bin/sh

# Emit deterministic APT update counts without requiring python3-apt.
#
# When python3 and python-apt are available, keep using the structured
# metadata implementation.  Otherwise use only the already cached APT
# metadata through a read-only simulation.

set -u

python_script=${APT_COUNT_PYTHON_SCRIPT:-}
python_source_b64=${APT_COUNT_PYTHON_B64:-}

if command -v python3 >/dev/null 2>&1 &&
  python3 -c 'import apt' >/dev/null 2>&1; then
  if [ -n "$python_source_b64" ]; then
    python3 -c "import base64;exec(base64.b64decode('$python_source_b64'))"
  elif [ -n "$python_script" ] && [ -r "$python_script" ]; then
    python3 "$python_script"
  else
    script_dir=$(cd -- "$(dirname -- "$0")" && pwd)
    python3 "$script_dir/apt-count.py"
  fi
  exit $?
fi

command -v apt-get >/dev/null 2>&1 || {
  printf 'APT_COUNTS|unknown|unknown|unknown|false\n'
  exit 2
}

simulation=$(LC_ALL=C LANG=C apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null) || {
  printf 'APT_COUNTS|unknown|unknown|unknown|false\n'
  exit 2
}

counts=$(printf '%s\n' "$simulation" | awk '
  BEGIN { valid = 1; total = 0; normal = 0; security = 0 }
  /^Inst[[:space:]]/ {
    if ($0 !~ /^Inst[[:space:]][^[:space:]]+[[:space:]]+\[[^]]*\][[:space:]]+\([^)]/) {
      valid = 0
      next
    }
    total++
    line = tolower($0)
    if (line ~ /security/) security++
    else normal++
  }
  END {
    if (!valid || normal + security != total)
      exit 1
    printf "%d|%d|%d|true\n", total, normal, security
  }
') || {
  printf 'APT_COUNTS|unknown|unknown|unknown|false\n'
  exit 2
}

printf 'APT_COUNTS|%s\n' "$counts"
