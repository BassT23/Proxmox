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

assert "ONLY has priority for each run type; EXCLUDE is ignored while that ONLY filter is set." in page
assert "content:'↳'" not in page
assert "columns:[['CHECK_WITH_LXC','CHECK_RUNNING_CONTAINER','CHECK_STOPPED_CONTAINER','WITH_LXC','RUNNING_CONTAINER','STOPPED_CONTAINER'],['LXC_START_DELAY','BACKUP_LXC_MP']]" in page
assert "columns:[['CHECK_WITH_VM','CHECK_RUNNING_VM','CHECK_STOPPED_VM','CHECK_PAUSED_VM','WITH_VM','RUNNING_VM','STOPPED_VM'],['VM_START_DELAY']]" in page
assert "data-parent" not in page
assert "updateConfigDependencies" not in page
assert "is-dependent" not in page
assert "update.conf remains the source of truth" in page
assert "/api/config-preview?" in page
assert "filter-preview" in page
assert "Ignored while ONLY is active" in page
assert "ONLY has priority for each run type" in page
assert "ONLY has priority for each run type; EXCLUDE is ignored while that ONLY filter is set." in page
assert "ONLY','EXCLUDE" in page
assert "filterGroups" in page
assert "preview:'check'" in page
assert "preview:'update'" in page
assert "scope==='update'" in page
assert "Update host" in page
assert "Update running containers" in page
assert "setLoginLoading(true)" in page
assert "button.disabled=loading" in page
assert "Login successful" in page
assert "Login failed" in page
assert "form.dataset.submitting==='true'" in page
assert "login-spinner" in page

# Contextual help uses one reusable, keyboard-accessible pattern for both views.
assert page.count("class=\"help-control\"") >= 1
assert "class=\"help-trigger\"" in page
assert "aria-label=\"About Systems\"" in page
assert "aria-controls=\"systems-help-popover\"" in page
assert "Systems shows the complete active inventory grouped by Proxmox node and external target." in page
assert "Guests without current update information remain part of the inventory" in page
assert "The check and update previews show the targets that would be included in the respective run" in page
assert "Opening or changing the preview does not contact any target." in page
assert "function createHelpControl(label,paragraphs)" in page
assert "event.key!=='Escape'" in page
assert "closeHelpControls()" in page
assert "help-trigger:focus-visible" in page
assert "caret-color:transparent" in page
assert "new Intl.Collator(undefined,{numeric:true,sensitivity:'base'})" in page
assert "const sortNodes=items=>[...items].sort" in page
assert "nodes=sortNodes(ts.filter(isProxmoxNode))" in page
assert "externalGroup(external)" in page
assert "grid-template-rows:auto auto" in page
assert ".node-group .group-summary { grid-column:2; grid-row:2; display:flex; flex-wrap:wrap" in page
assert ".config-field.boolean-field { width:fit-content; max-width:100%; justify-self:start; cursor:pointer }" in page
assert ".config-field.boolean-field:hover" in page
assert 'class="filter-preview-chevron">›' not in page
assert 'class="filter-preview-chevron" aria-hidden="true"' in page
assert ".filter-preview-chevron::after" in page
assert "<span class=\"chevron\" aria-hidden=\"true\"></span>" in page

# Presentation must not expose the internal host: prefix in detail/job labels.
assert "friendlyTarget(t)" in page
assert "friendlyJobTarget(j.target)" in page
assert "replace(/^host:/,'')" in page

print("web config UI grouping tests: PASS")
