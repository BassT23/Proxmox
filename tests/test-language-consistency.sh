#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

# Project-owned runtime and documentation text must remain English.  External
# human-readable output is not a runtime protocol and must not be parsed by
# the Welcome screen.
pattern='Fehler|fehlgeschlagen|Erfolgreich|Ergebnis|verfügbar|Neustart|erforderlich|erreichbar|geprüft|weitere Systeme|keine Updates|Einstellungen|Benachrichtigung|Abbrechen|Schließen|Speichern|Löschen|Zurück|Auswahl|Prüfung|deaktiviert|aktiviert|wird|wurde|werden|[ÄÖÜäöüß]'

matches=$(git grep -n -I -E "$pattern" -- \
  '*.sh' '*.py' '*.md' '*.conf*' 'ultimate-updater' \
  ':!welcome-screen.sh' \
  ':!tests/**' \
  ':!web-ui/assets/vendor/**' \
  ':!LICENSE' \
  ':!pictures/**' || true)

if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches" >&2
  echo 'project-owned language consistency: FAIL' >&2
  exit 1
fi

if grep -Eq 'Fetched|Es wurden|Paketlisten werden gelesen|Reading package lists|Temporary failure resolving' \
  welcome-screen.sh; then
  echo 'language-dependent external-output matcher remains in welcome-screen.sh' >&2
  exit 1
fi

if grep -Eq "check-output.*grep|grep.*check-output" status-model.sh; then
  echo 'security/status logic still parses check-output' >&2
  exit 1
fi

echo 'language consistency: PASS'
