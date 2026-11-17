#!/usr/bin/env bash
# shellcheck disable=SC2016 # Source assertions intentionally use literals.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

mkdir "$WORK_DIR/fake-bin"
cat > "$WORK_DIR/fake-bin/apt-get" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == update ]] || exit 64
SH
cat > "$WORK_DIR/fake-bin/id" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == -u ]] && printf '0\n' || /usr/bin/id "$@"
SH
chmod 755 "$WORK_DIR/fake-bin/apt-get" "$WORK_DIR/fake-bin/id"

# Both count helpers report what they received, so each path shows whether
# INCLUDE_PHASED_UPDATES reached the count on the target.
cat > "$WORK_DIR/apt-count.py" <<'PY'
import os

print("APT_COUNTS|0|0|0|true|phased=" + os.environ.get("UU_INCLUDE_PHASED_UPDATES", "unset"))
PY
cat > "$WORK_DIR/apt-count.sh" <<'SH'
#!/usr/bin/env sh
printf 'APT_COUNTS|0|0|0|true|phased=%s\n' "${UU_INCLUDE_PHASED_UPDATES:-unset}"
SH
chmod 755 "$WORK_DIR/apt-count.sh"

export PATH="$WORK_DIR/fake-bin:$PATH"
export LOCAL_FILES="$WORK_DIR"
export APT_COUNT_SCRIPT="$WORK_DIR/apt-count.py"

# check-updates.sh keeps its own copy of these helpers for installations
# without target-runtime.sh; extract that block so both copies are covered.
awk '/^TARGET_RUNTIME_FILE=/ {f=1} f {print} f && /^fi$/ {exit}' \
  "$ROOT_DIR/check-updates.sh" > "$WORK_DIR/check-updates-legacy.sh"
grep -Fq 'READ_APT_UPDATE_COUNTS()' "$WORK_DIR/check-updates-legacy.sh"
grep -Fq 'APT_COUNT_REMOTE_COMMAND()' "$WORK_DIR/check-updates-legacy.sh"

check_paths() {
  local runtime="$1" setting="$2" expected="$3" shell_script command output
  for shell_script in "$WORK_DIR/apt-count.sh" "$WORK_DIR/missing-apt-count.sh"; do
    # Local count: the result line keeps the helper's trailing field.
    output=$(
      export APT_COUNT_SHELL_SCRIPT="$shell_script" TARGET_RUNTIME_FILE="$WORK_DIR/missing-target-runtime.sh"
      if [[ "$setting" == unset ]]; then
        unset INCLUDE_PHASED_UPDATES
      else
        export INCLUDE_PHASED_UPDATES="$setting"
      fi
      # shellcheck disable=SC1090
      source "$runtime"
      PARSE_APT_UPDATE_COUNTS() { printf '%s\n' "$1"; }
      READ_APT_UPDATE_COUNTS
    )
    [[ "$output" == *"|phased=$expected" ]] || {
      printf 'local %s (%s, %s): %s\n' "$runtime" "$setting" "$shell_script" "$output" >&2
      exit 1
    }

    # Remote count: the generated command runs in a fresh shell on the target,
    # where the updater's configuration is not in the environment.
    command=$(
      export APT_COUNT_SHELL_SCRIPT="$shell_script" TARGET_RUNTIME_FILE="$WORK_DIR/missing-target-runtime.sh"
      if [[ "$setting" == unset ]]; then
        unset INCLUDE_PHASED_UPDATES
      else
        export INCLUDE_PHASED_UPDATES="$setting"
      fi
      # shellcheck disable=SC1090
      source "$runtime"
      APT_COUNT_REMOTE_COMMAND
    )
    output=$(env -u INCLUDE_PHASED_UPDATES -u UU_INCLUDE_PHASED_UPDATES bash -c "$command")
    [[ "$output" == *"|phased=$expected" ]] || {
      printf 'remote %s (%s, %s): %s\n' "$runtime" "$setting" "$shell_script" "$output" >&2
      exit 1
    }
  done
}

for runtime in "$ROOT_DIR/target-runtime.sh" "$WORK_DIR/check-updates-legacy.sh"; do
  check_paths "$runtime" unset false
  check_paths "$runtime" false false
  check_paths "$runtime" true true
done

# The check reads the setting from update.conf like update.sh does.
grep -Fq "INCLUDE_PHASED_UPDATES=\$(awk -F'\"' '/^INCLUDE_PHASED_UPDATES=/ {print \$2}' \"\$CONFIG_FILE\")" \
  "$ROOT_DIR/check-updates.sh"

echo 'APT phased-update setting propagation tests: PASS'
