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
assert 'Scheduled checks and updates are planned for a future release.' in page
assert 'function applyPageRoute(push=false)' in page
assert "location.pathname==='/settings'" in page
assert "location.pathname==='/scheduler'" in page
assert "document.getElementById('settings-page').hidden=page!=='settings'" in page
assert "document.getElementById('scheduler-page').hidden=page!=='scheduler'" in page
assert "document.querySelector('.dashboard-kpis').hidden=page!=='overview'" in page
assert 'id="config-form"' in page
assert 'id="config-message"' in page
# Overview does not duplicate the settings editor or a redundant settings card.
overview = page.split('id="overview-page"', 1)[1].split('id="settings-page"', 1)[0]
assert 'id="settings-entry"' not in overview
assert 'Manage Ultimate Updater settings' not in overview
assert 'id="config-form"' not in overview
settings = page.split('id="settings-page"', 1)[1].split('id="scheduler-page"', 1)[0]
assert 'id="config-form"' in settings
assert 'class="management-form open"' in settings
assert 'Open editor' not in settings
assert 'background:#151d34e8' in page
assert 'min-width:112px' in page
assert '.page-nav a.active' in page
# The placeholder must not expose scheduling controls or job endpoints.
scheduler = page.split('id="scheduler-page"', 1)[1].split('<footer', 1)[0]
assert '<input' not in scheduler
assert '<select' not in scheduler
assert '/api/' not in scheduler

print("web page structure regression tests: PASS")
