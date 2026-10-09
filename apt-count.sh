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
    # APT writes the candidate as:
    #   Inst package [old-version] (new-version archive/suite [arch])
    # Dependency annotations can follow the closing parenthesis.  Only the
    # archive/suite tokens inside that candidate section are relevant for the
    # security classification; package names and versions are not.
    if (NF < 6 || $1 != "Inst" || $2 == "" ||
        $3 !~ /^\[[^]]*\]$/ || $4 !~ /^\(/) {
      valid = 0
      next
    }

    candidate_closed = 0
    repository = ""
    for (i = 5; i <= NF; i++) {
      token = $i
      if (token ~ /\)$/) {
        sub(/\)$/, "", token)
        if (token !~ /^\[[^]]+\]$/) {
          valid = 0
        } else {
          candidate_closed = 1
        }
        break
      }
      repository = repository " " token
    }
    if (!candidate_closed || repository ~ /^[[:space:]]*$/) {
      valid = 0
      next
    }

    total++
    repository = tolower(repository)
    # Match a complete security component in repository/archive metadata,
    # such as stable-security or Debian-Security:13/stable-security.  This
    # deliberately does not match names such as security-tools.
    if (repository ~ /(^|[[:space:]\/:,-])security([[:space:]\/:,-]|$)/)
      security++
    else
      normal++
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
