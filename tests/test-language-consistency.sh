#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

# Project-owned runtime and documentation text must remain English.  The
# localized strings intentionally used to recognize external APT/DNS output
# are excluded here and checked explicitly below.
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

for matcher in \
  'Paketlisten werden gelesen' \
  'Abhängigkeitsbaum wird aufgebaut' \
  'Statusinformationen werden eingelesen' \
  'Alle Pakete sind aktuell' \
  'Temporärer Fehlschlag beim Auflösen' \
  'Konnte .* nicht auflösen'; do
  grep -Fq "$matcher" welcome-screen.sh || {
    echo "localized input matcher missing: $matcher" >&2
    exit 1
  }
done

echo 'language consistency: PASS'
