#!/usr/bin/env python3
"""Static regression checks for the grouped configuration UI."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


page = server.PAGE

for title in (
    "Host", "Containers / LXC", "Virtual Machines", "Target filters",
    "General update behavior", "Backup & safety", "Notifications",
):
    assert f"title:'{title}'" in page, title

assert "ONLY has priority; EXCLUDE is ignored while ONLY is set." in page
assert "content:'↳'" not in page
assert "columns:[['CHECK_WITH_LXC','CHECK_RUNNING_CONTAINER','CHECK_STOPPED_CONTAINER'],['LXC_START_DELAY','BACKUP_LXC_MP']]" in page
assert "columns:[['CHECK_WITH_VM','CHECK_RUNNING_VM','CHECK_STOPPED_VM','CHECK_PAUSED_VM'],['VM_START_DELAY']]" in page
assert "data-parent" not in page
assert "updateConfigDependencies" not in page
assert "is-dependent" not in page
assert "update.conf remains the source of truth" in page

# Presentation must not expose the internal host: prefix in detail/job labels.
assert "friendlyTarget(t)" in page
assert "friendlyJobTarget(j.target)" in page
assert "replace(/^host:/,'')" in page

print("web config UI grouping tests: PASS")
