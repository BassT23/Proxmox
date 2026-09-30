#!/usr/bin/env python3
"""Static regression checks for user-owned target-selection persistence."""

from pathlib import Path

ROOT = Path(__file__).parents[1]
server = (ROOT / "web-ui/server.py").read_text(encoding="utf-8")
installer = (ROOT / "install.sh").read_text(encoding="utf-8")

assert 'rm -f "$TEMP_FILES"/target-selection.json' in installer
assert 'cp "$TEMP_FILES"/target-selection.json' not in installer
assert 'mv "$TEMP_FILES"/target-selection.json' not in installer
assert "clearTimeout(targetSelectionSaveTimer);targetSelectionSaveQueued=false;targetSelectionRevision+=1" in server
assert "targetSelectionConfirmed=copyTargetSelection(targetSelection)" in server
bootstrap = server[server.index("async function bootstrap"):server.index("const aggregateField")]
assert "await loadTargetSelection()" in bootstrap
assert "saveTargetSelection" not in bootstrap
assert "queueTargetSelectionSave" not in bootstrap
print("target selection persistence tests: PASS")
