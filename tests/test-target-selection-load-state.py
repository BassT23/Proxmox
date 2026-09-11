"""Regression checks for explicit target-selection loading states."""

from pathlib import Path
import sys

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


page = server.PAGE
assert "targetSelectionLoadState='loading'" in page
assert "targetSelectionLoadRevision=0" in page
assert "Target selection: Loading…" in page
assert "Target selection: Unavailable" in page
assert "targetSelectionLoadState='ready'" in page
assert "data.selection||targetSelection" not in page[page.index("async function loadTargetSelection"):page.index("function selectionControls")]
assert "targetSelectionLoadState='error'" in page
assert "button.disabled=unavailable" in page
assert "selectionLoadState==='loading'" not in page  # state is held in targetSelectionLoadState
assert "function retryTargetSelection()" in page
assert "target-selection-retry" in page
assert "await loadTargetSelection()" in page[page.index("async function bootstrap"):page.index("const aggregateField")]
login_handler = page[page.index("document.getElementById('login-form').onsubmit"):page.index("const logout")]
assert "loadTargetSelection()" in login_handler
assert "Promise.all([loadStatus(),loadJobs(),loadTargets(),loadTargetSelection()])" in login_handler
assert "saveTargetSelection" not in page[page.index("async function loadTargetSelection"):page.index("function retryTargetSelection")]
assert "read_target_selection_for_api" in server.__dict__
print("target selection load-state tests: PASS")
