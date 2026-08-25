#!/usr/bin/env python3
"""Regression coverage for the protected Overview/Settings/Scheduler layout."""

import importlib.util
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
page = server.PAGE

assert 'data-page="overview"' in page
assert 'data-page="settings"' in page
assert 'data-page="scheduler"' in page
assert 'href="/settings"' in page
assert 'href="/scheduler"' in page
assert 'id="overview-page"' in page
assert 'id="settings-page"' in page
assert 'id="scheduler-page"' in page
assert 'id="page-subtitle"' in page
assert 'Automatic checks and updates using the existing Ultimate Updater safety rules.' in page
assert 'Scheduling will be available in a future release.' not in page
assert '/api/schedules' in page
assert '/api/scheduler-targets' in page
assert 'Check all systems' in page
assert 'Check selected' in page
assert 'Update all systems' in page
assert 'Update selected' in page
assert 'function applyPageRoute(push=false,requestedPage=null)' in page
assert "location.pathname==='/settings'" in page
assert "location.pathname==='/scheduler'" in page
assert "document.getElementById('settings-page').hidden=page!=='settings'" in page
assert "document.getElementById('scheduler-page').hidden=page!=='scheduler'" in page
assert "document.querySelector('.dashboard-kpis').hidden=page!=='overview'" in page
assert "applyPageRoute(true,link.dataset.page)" in page
assert 'id="config-form"' in page
assert 'id="config-message"' in page
# Overview keeps status/action content only; management is on Settings.
overview = page.split('id="overview-page"', 1)[1].split('id="settings-page"', 1)[0]
assert 'id="settings-entry"' not in overview
assert 'Manage Ultimate Updater settings' not in overview
assert 'id="config-form"' not in overview
assert 'id="internal-ssh-card"' not in overview
assert 'id="external-panel"' not in overview
assert 'id="internal-ssh-view"' not in overview
assert 'id="targets"' in overview
assert 'id="jobs"' in overview
assert 'class="overview-actions-card"' in overview
assert 'id="check-all"' in overview
assert 'id="update-all"' in overview
settings = page.split('id="settings-page"', 1)[1].split('id="scheduler-page"', 1)[0]
assert 'id="config-form"' in settings
assert 'class="management-form open"' in settings
assert 'class="summary dashboard-kpis"' not in settings
assert 'Open editor' not in settings
assert 'id="internal-ssh-card"' in settings
assert 'id="internal-ssh-view"' in settings
assert 'id="external-panel"' in settings
assert 'id="target-add"' in settings
assert '<h2 class="settings-management-title">' not in settings
assert 'Settings' not in settings.split('id="config-panel"', 1)[0]
assert 'Configure the existing Ultimate Updater behavior.' not in settings
assert 'class="settings-config-intro section-title"' not in settings
assert '<section class="global-actions"' not in settings
assert '<button id="internal-ssh-back" type="button">Close</button>' in settings
assert '#settings-page .connection-management-grid' in page
assert "groupData.title==='Host'" in page
assert "groupData.title==='Target filters'" in page
assert "groupData.title==='Containers / LXC'" not in page.split('function buildConfigForm', 1)[1].split('function configField', 1)[0]
assert "await ensureSession();showDashboard();applyPageRoute();" in page
assert 'class="summary dashboard-kpis" hidden' not in page
summary = page.split('id="overview-page"', 1)[1].split('id="settings-page"', 1)[0]
assert 'class="summary dashboard-kpis"' in summary
assert summary.count('class="metric"') == 6
assert '.dashboard-kpis { grid-template-columns:repeat(6,minmax(0,1fr))' in page
assert '.dashboard-kpis .metric' in page
assert '#settings-page #config-form.management-form.open' in page
assert 'settings-group-wide' in page
assert 'grid-template-columns:repeat(2,minmax(0,1fr))' in page
assert '#settings-page #config-form.management-form.open { grid-template-columns:1fr }' in page
assert 'background:#151d34e8' in page
assert 'min-width:112px' in page
assert '.page-nav a.active' in page
# Scheduler exposes only the supported full check/update controls.
scheduler = page.split('id="scheduler-page"', 1)[1].split('<footer', 1)[0]
assert 'class="summary dashboard-kpis"' not in scheduler
assert 'name="time"' in scheduler
assert 'name="days"' in scheduler
assert 'Select all visible' in scheduler
assert 'schedule-target-table' in scheduler
assert 'schedule-selected' in scheduler
assert 'name="type"' in scheduler
assert 'id="scheduler-timezone"' not in scheduler
assert '<span>Timezone</span>' not in scheduler
assert '.scheduler-summary{display:grid;grid-template-columns:repeat(3' in page
assert '/api/schedules' in page
assert 'name="frequency"' not in scheduler
assert 'name="day"' not in scheduler
assert 'single system' not in scheduler.lower()

print("web page structure regression tests: PASS")
