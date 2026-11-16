#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/apt.py" <<'PY'
import os


class Origin:
    def __init__(self, value):
        self.origin = value
        self.archive = value
        self.codename = value
        self.label = value
        self.site = "fixture.example" if value else ""
        self.component = "main" if value else ""


class Candidate:
    def __init__(self, origin):
        self.origins = [Origin(origin)]


class Package:
    def __init__(self, upgrade, origin, phased=False):
        self.is_upgradable = upgrade
        self.candidate = Candidate(origin)
        self.phased = phased
        self._pkg = self


class DepCache:
    @staticmethod
    def phasing_applied(package):
        return package.phased


class Cache:
    def __init__(self):
        scenario = os.environ.get("APT_FIXTURE", "mixed")
        values = {
            "zero": [],
            "normal": [Package(True, "stable") for _ in range(5)],
            "security": [Package(True, "stable-security") for _ in range(2)],
            "mixed": [Package(True, "stable-security") for _ in range(2)] +
                     [Package(True, "stable") for _ in range(5)],
            "third-party": [Package(True, "vendor")],
            "unknown": [Package(True, "")],
            "phased": [Package(True, "stable", phased=True) for _ in range(3)] +
                      [Package(True, "stable") for _ in range(2)],
        }
        self.packages = values[scenario]
        if scenario == "phased":
            self._depcache = DepCache()

    def __iter__(self):
        return iter(self.packages)
PY

for scenario in zero normal security mixed third-party; do
  case "$scenario" in
    zero) expected='APT_COUNTS|0|0|0|true' ;;
    normal) expected='APT_COUNTS|5|5|0|true' ;;
    security) expected='APT_COUNTS|2|0|2|true' ;;
    mixed) expected='APT_COUNTS|7|5|2|true' ;;
    third-party) expected='APT_COUNTS|1|1|0|true' ;;
  esac
  actual=$(APT_FIXTURE="$scenario" PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
  [[ "$actual" == "$expected" ]]
done

# Updates that apt defers because of phasing are not counted, since an upgrade
# run never installs them, unless the updater is configured to include them.
phased=$(APT_FIXTURE=phased PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
[[ "$phased" == 'APT_COUNTS|2|2|0|true' ]]
phased=$(UU_INCLUDE_PHASED_UPDATES=true APT_FIXTURE=phased PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
[[ "$phased" == 'APT_COUNTS|5|5|0|true' ]]
phased=$(UU_INCLUDE_PHASED_UPDATES=false APT_FIXTURE=phased PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
[[ "$phased" == 'APT_COUNTS|2|2|0|true' ]]

# The structured helper does not consume command output, so localized raw
# package-manager chatter cannot affect its result.
printf '%s\n' 'Fetched 10 packages' 'Es wurden 10 Pakete geholt' 'Téléchargé 10 paquets' \
  > "$WORK_DIR/raw-a"
printf '%s\n' 'Pobrano 10 pakietów' '任意のパッケージマネージャー出力' > "$WORK_DIR/raw-b"
raw_a=$(APT_FIXTURE=mixed PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
raw_b=$(APT_FIXTURE=mixed PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
[[ "$raw_a" == "$raw_b" ]]
for locale in C en_US.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 es_ES.UTF-8; do
  localized=$(env -u LC_ALL LANG="$locale" LC_MESSAGES="$locale" \
    APT_FIXTURE=mixed PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py")
  [[ "$localized" == 'APT_COUNTS|7|5|2|true' ]]
done

if APT_FIXTURE=unknown PYTHONPATH="$WORK_DIR" python3 "$ROOT_DIR/apt-count.py" > "$WORK_DIR/unknown-result"; then
  echo 'unknown APT origin was accepted' >&2
  exit 1
fi
grep -Fxq 'APT_COUNTS|unknown|unknown|unknown|false' "$WORK_DIR/unknown-result"

if python3 -S "$ROOT_DIR/apt-count.py" > "$WORK_DIR/missing-apt"; then
  echo 'missing python3-apt was accepted' >&2
  exit 1
fi
grep -Fxq 'APT_COUNTS|unknown|unknown|unknown|false' "$WORK_DIR/missing-apt"

echo 'structured APT count tests: PASS'
