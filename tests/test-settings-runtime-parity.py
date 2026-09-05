#!/usr/bin/env python3
"""Static coverage checks for Web UI settings and runtime boundaries."""

import re
from pathlib import Path

ROOT = Path(__file__).parents[1]
import sys
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


runtime_sources = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (
        ROOT / "update.sh",
        ROOT / "check-updates.sh",
        ROOT / "update-extras.sh",
        ROOT / "global-update.sh",
        ROOT / "external-selection.sh",
        ROOT / "status-model.sh",
    )
)

# Every editable UI key must still have a runtime consumer.  This catches a
# field that is accidentally added to the form/whitelist without wiring it
# into the existing CLI/runtime paths.
labels = re.search(r"const configLabels=\{(.*?)\};", server.PAGE, re.S)
assert labels, "configLabels missing"
visible_keys = set(re.findall(r"([A-Z][A-Z0-9_]+):", labels.group(1)))
assert visible_keys == server.CONFIG_KEYS, sorted(visible_keys ^ server.CONFIG_KEYS)
orphaned = sorted(key for key in visible_keys if not re.search(rf"\b{re.escape(key)}\b", runtime_sources))
assert not orphaned, orphaned

# The Web UI must use the same CLI/job-runner entry points as the documented
# actions; scope is enforced by the CLI/runtime, not by frontend filtering.
source = (ROOT / "web-ui/server.py").read_text(encoding="utf-8")
assert '"start-check", target' in source
assert '"start-check", "all-systems"' in source
assert 'str(self.server.cli), "update-all"' in source
assert 'str(self.server.cli), "update-node", node' in source
assert '"start-selfupdate"' in source

cli = (ROOT / "ultimate-updater").read_text(encoding="utf-8")
runner = (ROOT / "job-runner.sh").read_text(encoding="utf-8")
assert 'UU_UPDATE_SCOPE=host "$JOB_RUNNER" start "$UPDATE_SCRIPT" host' in cli
assert 'UU_CHECK_SCOPE=host STATUS_MODEL_PARTIAL=true "$CHECK_SCRIPT" node-host' in cli
assert '"${UU_CHECK_SCOPE:-}" != host && "$WITH_LXC" == true' in (ROOT / "check-updates.sh").read_text(encoding="utf-8")
assert '"${UU_UPDATE_SCOPE:-}" == host' in (ROOT / "update.sh").read_text(encoding="utf-8")
assert '"--setenv=UU_UPDATE_SCOPE=host"' in runner

print(f"settings runtime parity: PASS ({len(visible_keys)} editable keys, no orphaned consumers)")
