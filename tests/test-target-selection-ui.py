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
assert 'id="system-bulk-selection"' not in page
assert 'class="system-bulk-selection"' not in page
assert "Include in global actions" not in page
assert "target-selection-indicator" in page
assert "Global actions" in page
assert "Target selection: Loading…" in page
assert "Default = no explicit rule · Only = explicitly include · Exclude = explicitly omit" in page
assert "Check all" in page
assert "Update all" in page
assert "[['','Default'],['only','Only'],['exclude','Exclude']]" in page
assert "selectionStateLabel" in page
assert "select.target-selection-state" in page
assert "label?.setAttribute('for',inputId)" in page
assert "saveTargetSelection(scope,id,current,desired)" in page
assert "guest-table-header" in page
assert "Target</span><span role=\"columnheader\">Status" in page
assert "Global actions<small><span>Check all</span><span>Update all</span>" in page
assert "role=\"columnheader\">Actions" in page
assert "grid-column:6 / span 2" in page
assert "selectionFields=[...selection.querySelectorAll('select.target-selection-state')]" in page
assert "cell.className=`row-global-actions row-global-selection ${index===0?'row-global-selection-check':'row-global-selection-update'}`" in page
assert "row-global-selection-check" in page
assert "row-global-selection-update" in page
assert ".target-row .row-global-selection-check { grid-column:6; }" in page
assert ".target-row .row-global-selection-update { grid-column:7; border-right:0; }" in page
assert ".guest-table-header > [role=\"columnheader\"]:last-child { grid-column:8; justify-self:stretch; text-align:center; }" in page
assert ".row-global-selection .target-selection-state { flex:0 0 auto; }" in page
assert "#system-bulk-selection + #targets { margin-top:18px; }" not in page
assert "target-updates" in page
assert "row-global-actions::before" not in page
assert "selectionFieldState=new Map()" in page
assert "sequence:(record?.sequence||0)+1" in page
assert "Saving selection…" in page
assert "setAttribute('aria-busy',String(Boolean(pending)))" in page
assert "flushTargetSelectionSave=async function()" in page
assert "batch=[...selectionFieldState.values()].filter(record=>record.revision<=revision)" in page
assert "if(!current||current.revision>revision)continue" in page
assert "insertGuestTableHeader" in page
assert "global-selection-controls" in page
assert "node-global-actions" in page
assert "row-global-actions" in page
assert ".node-global-actions { display:grid; grid-template-columns:max-content minmax(0,1fr); grid-template-rows:auto;" in page
assert ".node-global-actions::before { content:'Global actions'; grid-column:1; grid-row:1; width:auto;" in page
assert ".node-global-actions .global-selection-controls .target-selection-column,.row-global-actions .global-selection-controls .target-selection-column { display:flex; flex-direction:column;" in page
assert ".node-global-actions .global-selection-controls .target-selection-column { flex:0 0 auto; width:72px; }" in page
assert ".node-global-actions .global-selection-controls { display:grid; grid-column:2; grid-row:1; grid-template-columns:repeat(2,max-content); align-items:start; justify-self:end;" in page
assert ".node-global-actions .global-selection-controls .target-selection-label { width:100%; text-align:center; }" in page
assert ".node-global-actions .global-selection-controls .target-selection-state { box-sizing:border-box; display:block; width:72px !important; min-width:72px !important; max-width:72px !important; height:34px !important; min-height:34px !important; max-height:34px !important; flex:0 0 72px !important;" in page
assert ".guest-selection-state { box-sizing:border-box; display:block; width:92px !important; min-width:92px !important; max-width:92px !important; height:34px !important; min-height:34px !important; max-height:34px !important; flex:0 0 92px !important;" in page
assert "select.classList.add('guest-selection-state')" in page
assert "const selectionVariantClass=select=>select.dataset.selectionVariant==='guest'?' guest-selection-state':select.dataset.selectionVariant==='node'?' node-selection-state':'';" in page
assert "select.className='target-selection-state '+(state||'default')+(targetSelectionLoadState!=='ready'?' unavailable':'')+selectionVariantClass(select);" in page
assert "select.dataset.selectionVariant=nodeActions?'node':'target'" in page
assert "select.dataset.selectionVariant='guest'" in page
assert "node-selection-state" in page
assert ".target-row > :first-child { grid-column:1; grid-row:1; }" in page
assert ".target-row > .target-status { grid-column:2; grid-row:1; }" in page
assert ".target-row > .target-updates { grid-column:3; grid-row:1; }" in page
assert ".target-row > .row-os { grid-column:4; grid-row:1; }" in page
assert ".target-row > .row-last-check { grid-column:5; grid-row:1; }" in page
assert ".target-row .row-actions { display:flex; grid-column:8; grid-row:1; align-items:center; justify-content:center; width:100%; min-width:max-content; padding:0 8px; border:0; gap:6px; white-space:nowrap; }" in page
assert ".row-global-actions .global-selection-controls { display:flex; align-items:center; gap:8px; flex-wrap:nowrap;" in page
assert ".node-scope-help { margin-bottom:4px; line-height:1.35; }" in page
assert ".system-bulk-selection { margin-top:18px; padding:12px 14px 13px;" not in page
assert ".bulk-selection-copy { display:grid; gap:4px; min-width:0; }" not in page
assert "minmax(110px,.8fr) minmax(110px,.8fr) minmax(175px,max-content); min-width:1200px" in page
assert ".guest-table-header .header-global-actions { display:grid; grid-column:6 / span 2; gap:4px; text-align:center; justify-items:center; }" in page
assert ".guest-table-header .header-global-actions small { display:grid; grid-template-columns:1fr 1fr; gap:7px; width:100%; justify-items:center; color:#8fd2ff; font-size:.59rem; font-weight:700; text-transform:none; letter-spacing:0; text-align:center; }" in page
assert ".row-global-actions { display:flex; align-items:center; justify-content:center; min-width:0; margin:0; padding:0 4px; border-right:0; overflow:visible;" in page
assert ".row-global-actions { display:flex; align-items:center; justify-content:center; min-width:0; margin:0; padding:0 4px; border-right:1px solid #159cf055;" not in page
assert ".target-row .row-global-selection-check { grid-column:6; border-right" not in page
assert ".target-row .row-global-selection-update { grid-column:7; border-right:1px solid #159cf055; }" not in page
assert ".target-row .row-actions { min-width:max-content; white-space:nowrap; }" in page
assert ".node-group .group-actions .group-actions-label { flex:0 0 auto; margin-right:auto; }" in page
assert "Global actions for this node" in page
assert "Global actions for this target" in page
assert "selectionControls=function(t,nodeActions=false)" in page
assert "selectionHeader=()=>''" in page
assert "Only':state==='exclude'?'Exclude':'Default'" in page
assert "const legacyNodeGroup=nodeGroup" in page
assert "targetRow=function(t){const row=legacyTargetRow(t),actions=row.querySelector('.row-actions')" in page
assert "Check node" in page
assert "Update node" in page
assert ">Check</button>" in page
assert 'class="primary update"' in page
assert "Select targets for bulk action" not in page
assert "bulk-selection-mode" not in page
print("target selection optimistic UI tests: PASS")
