#!/usr/bin/env python3
"""Static regression checks for the grouped configuration UI."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


page = server.PAGE
source = Path(__file__).parents[1].joinpath("web-ui/server.py").read_text(encoding="utf-8")
runner_source = Path(__file__).parents[1].joinpath("job-runner.sh").read_text(encoding="utf-8")

for title in (
    "Host", "Containers / LXC", "Virtual Machines", "Target filters",
    "General update behavior", "Backup & safety", "Notifications",
):
    assert f"title:'{title}'" in page, title

assert "Leave Only empty to include all matching targets" in page
assert "If Only is empty, all matching targets are included except excluded ones." in page
assert "Check/Update node: Only this node. LXCs and VMs are not checked or updated." in page
assert "Only this Proxmox node will be updated. LXCs and VMs are not updated." in page
assert "content:'↳'" not in page
assert "matrix:[{label:'Containers',check:'CHECK_WITH_LXC',update:'WITH_LXC'},{label:'Running containers',check:'CHECK_RUNNING_CONTAINER',update:'RUNNING_CONTAINER'},{label:'Stopped containers',check:'CHECK_STOPPED_CONTAINER',update:'STOPPED_CONTAINER'}]" in page
assert "matrix:[{label:'Virtual machines',check:'CHECK_WITH_VM',update:'WITH_VM'},{label:'Running VMs',check:'CHECK_RUNNING_VM',update:'RUNNING_VM'},{label:'Stopped VMs',check:'CHECK_STOPPED_VM',update:'STOPPED_VM'},{label:'Paused VMs',check:'CHECK_PAUSED_VM',update:null}]" in page
assert "function configMatrix(groupData,values)" in page
assert "matrix-control" in page
assert "configField(row.check,values,true)" in page
assert "check-update-matrix" in page
assert "grid-template-columns:minmax(0,1fr) 58px 58px" in page
assert ".matrix-cell { display:grid; place-items:center; justify-items:center }" in page
assert "numeric-field" in page
assert ".config-field:not(.boolean-field).numeric-field .field-unit { grid-column:3; grid-row:1" in page
assert ".matrix-extras { display:grid; grid-template-columns:minmax(0,1fr) auto" in page
assert ".matrix-extra-row { display:flex; justify-self:start; align-items:center" in page
assert ".delay-control { display:inline-flex; flex:0 0 auto; align-items:center" in page
assert "row.className='matrix-extra-row'" in page
assert "control.className='delay-control'" in page
assert ".matrix-extras > .boolean-field { width:fit-content; justify-self:end" in page
assert ".check-update-matrix .config-field.boolean-field { justify-self:center }" in page
assert ".matrix-extras > .config-field.boolean-field { justify-self:end }" in page
assert ".matrix-control { width:fit-content; margin:0; justify-self:center" in page
assert ".matrix-empty { justify-self:center" in page
assert ".matrix-extras { display:grid; grid-template-columns:minmax(0,1fr) auto" in page
assert "data-parent" not in page
assert "updateConfigDependencies" not in page
assert "is-dependent" not in page
assert "update.conf remains the source of truth" in page
assert "/api/config-preview?" in page
assert "filter-preview" in page
assert "Ignored while ONLY is active" in page
assert "Leave it empty to include all matching targets." in page
assert "If Only is empty, all matching targets are included except excluded ones." in page
assert "ONLY','EXCLUDE" in page
assert "filterGroups" in page
assert "preview:'check'" in page
assert "preview:'update'" in page
assert "scope==='update'" in page
assert "Update host" in page
assert "Update running containers" in page
for key in (
    "VERSION_CHECK", "SSH_PORT", "EXE_FOR_INTERNET_CHECK", "URL_FOR_INTERNET_CHECK",
    "FREEBSD_UPDATES", "INCLUDE_PHASED_UPDATES", "INCLUDE_FSTRIM",
    "FSTRIM_WITH_MOUNTPOINT", "PACMAN_ENVIRONMENT", "INCLUDE_HELPER_SCRIPTS",
    "EXTRA_GLOBAL", "IN_HEADLESS_MODE", "PIHOLE", "IOBROKER", "PTERODACTYL",
    "OCTOPRINT", "DOCKER_COMPOSE", "UNIFI", "COMPOSE_PATH",
):
    assert key in server.CONFIG_KEYS, key
assert "Advanced settings" in page
assert "Extra updates" in page
assert "setLoginLoading(true)" in page
assert "button.disabled=loading" in page
assert "Login successful" in page
assert "Login failed" in page
assert "form.dataset.submitting==='true'" in page
assert "login-spinner" in page

# Internal SSH settings stay compact: nodes are complete, while guest entries
# are limited to configured profiles/overrides and offer an inventory-backed
# add flow for the remaining known guests.
assert "Internal SSH Connections" in page
assert "Open SSH settings" in page
assert "internal-ssh-view" in page
assert "+ Add VM SSH connection" in source
assert "+ Add LXC SSH connection" in source
assert "internalSshAvailable" in page
assert '"available":' in source
assert "kind = \"lxc\"" in source
assert "kind==='vm'?'VM':'CT'" in source
assert "${t.id} · ${t.name||t.id}" in source
assert "Existing SSH profile (legacy format)" in source
assert "QGA/default" in source
assert "internal_ssh_available_targets" in source
assert "kind not in {\"node\", \"vm\", \"lxc\"}" in source
assert "nodes are detected automatically" in page.lower()
assert "External systems are managed separately under External Targets." in page
assert "No additional VM SSH connections configured." in source
assert "No additional LXC SSH connections configured." in source
assert "Host unreachable." in source
assert "Connection timed out." in source
assert "Authentication failed." in source
assert "Host key verification failed." in source
assert "Connection refused." in source
assert "Could not load Internal SSH connections." in source
assert "internal-ssh-retry" in source
assert "Edit SSH settings" in page
assert "Add SSH connection" in page
assert "Use custom SSH settings" in page
assert page.count("Use custom SSH settings for this system.") == 1
assert "internalSshTargetLabel" in source
assert "target_choice.required=false" in source
assert "picker.required=true" in source
assert "key.split(':',2)" in source
assert "form.dataset.targetKey=key" in source
assert "t=internalSshTargets.find(item=>item.kind===kind&&item.id===id)" in source
assert "||internalSshAvailable.find" not in source.split("function openInternalSsh(key)", 1)[1].split("function openInternalSshAdd", 1)[0]
assert "target_choice.value=''" in source
assert "setInternalSshView(true)" in source
assert "loadInternalSsh()" in source

# Contextual help uses one reusable, keyboard-accessible pattern for both views.
assert page.count("class=\"help-control\"") >= 1
assert "class=\"help-trigger\"" in page
assert "aria-label=\"About Systems\"" in page
assert "aria-controls=\"systems-help-popover\"" in page
assert "Systems shows the complete active inventory grouped by Proxmox node and external target." in page
assert "Guests without current update information remain part of the inventory" in page
assert "Only limits the check or update to targets with this tag." in page
assert "Opening or changing the preview does not contact any target." in page
assert "function createHelpControl(label,paragraphs)" in page
for title in (
    "Host", "Containers / LXC", "Virtual Machines", "Target filters",
    "General update behavior", "Advanced settings", "Extra updates",
    "Backup & safety", "Notifications",
):
    assert f"'{title}':" in page, title
assert "Backup mode is limited to stop, suspend, or snapshot." in page
assert "Backup storage expects a Proxmox storage ID" in page
assert "Internet check defaults to command ping and address google.com." in page
assert "SSH port default: 22." in page
assert "config-field select" in page
assert "reboot-required-badge" in page
assert "Reboot required" in page
assert ".job-download { display:inline-flex" in page
assert ".log-actions + .log { margin-top:8px }" in page
assert "node.insertAdjacentElement('beforebegin',actions)" in source
assert "node.insertAdjacentElement('afterend',actions)" not in source
assert ".config-actions { position:static; background:transparent; }" in page
assert "Internal SSH Connections <span class=\"help-control\">" in page
assert "CONFIG_ENUMS" in source
try:
    server.validate_config_values({"BACKUP_MODE": "invalid"})
except ValueError as error:
    assert "stop" in str(error) and "snapshot" in str(error)
else:
    raise AssertionError("invalid BACKUP_MODE was accepted")
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
assert ".node-group .group-status" in page
assert ".node-group .group-status { display:flex" in page
assert ".node-group .group-header { grid-template-columns:32px minmax(0,1fr); grid-template-rows:auto auto;" in page
assert ".node-group .group-title strong,.node-group .group-title small { white-space:nowrap;" in page
assert ".node-group .group-status { grid-column:2; grid-row:2;" in page
assert "${statusBadges}" in source
assert ".node-group .group-updates" in page
assert ".node-group .group-actions" in page
assert "<div class=\"group-header\"><button class=\"group-toggle\"" in page
assert "</div><div class=\"group-info\"><span class=\"group-updates\"" in page
assert "</span></div><div class=\"group-actions\">" in source
assert "</span>${rebootBadge}</div>" not in source
assert "<div class=\"group-actions\"><button class=\"node-action node-check\"" in page
assert "<div class=\"group-status\">" in page
assert "sortNodes(ts.filter(isProxmoxNode))" in page
assert "config-field.boolean-field { width:fit-content" in page
assert 'class="filter-preview-chevron">›' not in page
assert 'class="filter-preview-chevron" aria-hidden="true"' in page
assert ".filter-preview-chevron::after" in page
assert "<span class=\"chevron\" aria-hidden=\"true\"></span>" in page
assert "EXTERNAL_BACKUP_REQUIRED" in page
assert "allow_without_backup" in page
assert "Proceed without verified backup" in page

# Checks use the same persistent job history as updates and expose progress globally.
assert '"start-check"' in source
assert 'run-check' in runner_source
assert '"type": "check"' in source
assert "job-running-indicator" in page
assert "renderRunningIndicator" in page
assert "prefers-reduced-motion:reduce" in page

# Presentation must not expose the internal host: prefix in detail/job labels.
assert "friendlyTarget(t)" in page
assert "friendlyJobTarget(j.target)" in page
assert "replace(/^host:/,'')" in page

# External runtime rows expose status/actions only; configuration management
# remains in the separate management list below.
runtime_row = page.split("function targetRow(t)", 1)[1].split("document.getElementById('config-open')", 1)[0]
assert "class=\"edit-target\"" not in runtime_row
assert "class=\"remove-target\"" not in runtime_row
assert "data-edit=\"${esc(t.id)}\"" in page
assert "data-test=\"${esc(t.id)}\"" in page
assert "data-remove=\"${esc(t.id)}\"" in page
assert "textContent='Settings'" in page

print("web config UI grouping tests: PASS")
