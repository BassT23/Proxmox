#!/usr/bin/env python3
"""Static contract checks for responsive, optimistic target-selection UI."""

from pathlib import Path
import sys

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


page = server.PAGE
assert "button.dataset.selectionId=id" in page
assert "paintTargetSelection()" in page
assert "queueTargetSelectionSave()" in page
assert "setTimeout(flushTargetSelectionSave,180)" in page
assert "targetSelectionRevision" in page
assert "if(revision===targetSelectionRevision)" in page
assert "rollbackTargetSelection()" in page
assert "Could not save target selection." in page
assert "await loadStatus()" not in page[page.index("function saveTargetSelection"):page.index("const targetRowWithSelection")]
assert ".target-selection-state{box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;width:26px;min-width:26px;height:26px;min-height:26px;padding:0" in page
assert ".target-selection-state{width:30px;min-width:30px;height:30px;min-height:30px" in page
assert "selectionLabel(state)" in page
print("target selection optimistic UI tests: PASS")
