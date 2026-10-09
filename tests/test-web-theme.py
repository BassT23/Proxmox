#!/usr/bin/env python3
"""Behavioral regression coverage for the Web UI theme preference."""

import importlib.util
import re
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
page = module.PAGE

assert 'data-theme="classic"' in page
assert "value==='classic'?'classic':'modern'" in page
assert "localStorage.getItem('ultimate-updater-theme')" in page
assert 'id="theme-select"' in page
assert '<option value="modern">Modern</option>' in page
assert '<option value="classic">Classic</option>' in page
assert 'html[data-theme="classic"]' in page
assert '--surface-terminal:' in page
assert '--theme-card-radius:' in page

# The node action markup is generated dynamically.  Tie the Classic selector
# check to that actual template so a selector aimed at the old group-summary
# container cannot silently pass while the rendered buttons remain Modern.
node_markup = re.search(r'card\.innerHTML=`(.*?group-actions.*?)`;const nodeGate', page).group(1)
assert '<div class="group-actions">' in node_markup
buttons = dict(re.findall(r'<button class="([^"]+)"[^>]*>([^<]+)</button>', node_markup))
assert buttons['node-action node-check'] == 'Check node'
assert buttons['node-action node-update'] == 'Update node'
assert buttons['node-details'] == 'Details'
for button_class in ('node-action', 'node-details'):
    assert f'html[data-theme="classic"] .node-group .group-actions .{button_class}' in page
assert 'html[data-theme="classic"] .node-group .group-summary .node-action' not in page

# The final Classic cascade must also neutralize the later navigation and
# scheduler styles, and keep inner controls angular rather than relying only
# on the outer card radius.
for selector in (
    'html[data-theme="classic"] .dashboard-meta .page-nav',
    'html[data-theme="classic"] .dashboard-meta .nav-toggle',
    'html[data-theme="classic"] .settings-group h3',
    'html[data-theme="classic"] .schedule-targets',
    'html[data-theme="classic"] .day-toggles span',
    'html[data-theme="classic"] .scheduler-card',
    'html[data-theme="classic"] .node-group',
):
    assert selector in page
assert '--theme-card-radius:0' in page
assert '--theme-control-radius:0' in page
assert 'html[data-theme="classic"] .filter-preview' in page
assert 'html[data-theme="classic"] .filter-preview-chevron' in page
assert 'html[data-theme="classic"] .help-trigger' in page
assert 'html[data-theme="classic"] .config-field input[type="text"]' in page
assert 'html[data-theme="classic"] .internal-ssh-target-picker select' in page
assert 'html[data-theme="classic"] .filter-preview-toggle:focus-visible' in page
assert 'html[data-theme="classic"] .help-trigger:focus-visible' in page
assert 'html[data-theme="classic"] .filter-preview-toggle:hover' in page
assert 'html[data-theme="classic"] .help-control.open .help-trigger' in page
assert 'html[data-theme="classic"] .help-trigger {\n    border-radius:0;\n    border-color:#69737b;' in page
assert 'html[data-theme="classic"] #settings-page #config-form .settings-group' in page
assert 'html[data-theme="classic"] #settings-page .internal-ssh-view .settings-group' in page
assert 'html[data-theme="classic"] #settings-page #config-form .settings-group,\nhtml[data-theme="classic"] #settings-page .internal-ssh-view .settings-group' in page
assert 'html[data-theme="classic"] #settings-page .settings-group' not in page
assert 'html[data-theme="classic"] #settings-page .filter-scope' in page
assert 'html[data-theme="classic"] #settings-page .management-form input' in page
assert 'html[data-theme="classic"] .filter-preview,' in page
assert 'html[data-theme="classic"] .help-trigger,' in page
assert 'background:#252a2e' in page
assert 'background:#30373d' in page
assert 'html[data-theme="classic"] input:focus-visible' in page
assert 'html[data-theme="classic"] .day-toggles input:checked + span' in page

config_function = "function setConfigOpen" + page.split("function setConfigOpen", 1)[1].split("\n    function managementMessage", 1)[0]
config_script = f"""
const form = {{classList: {{toggle: () => {{}}}}}};
const document = {{getElementById: id => id === 'config-form' ? form : null, querySelector: () => null}};
const loadConfig = () => {{}};
{config_function}
setConfigOpen(true);
console.log('config toggle without legacy button: PASS');
"""
config_result = subprocess.run(["node", "-e", config_script], check=False, capture_output=True, text=True)
assert config_result.returncode == 0, config_result.stderr or config_result.stdout
assert "config toggle without legacy button: PASS" in config_result.stdout

normalize = re.search(r"const normalizeTheme=value=>.*?;", page).group(0)
supported = re.search(r"const SUPPORTED_THEMES=.*?;", page).group(0)
storage_key = re.search(r"const THEME_STORAGE_KEY=.*?;", page).group(0)
apply_theme = re.search(r"function applyTheme\(value,persist=false\)\{.*?\n", page).group(0)
node_script = f"""
{supported}
{storage_key}
{normalize}
let stored = {{}};
const select = {{value: ''}};
const document = {{documentElement: {{dataset: {{}}}}, getElementById: id => id === 'theme-select' ? select : null}};
const localStorage = {{getItem: key => stored[key] || null, setItem: (key, value) => stored[key] = value}};
{apply_theme}
const modern = applyTheme(undefined);
if (modern !== 'modern' || document.documentElement.dataset.theme !== 'modern') process.exit(1);
const classic = applyTheme('classic', true);
if (classic !== 'classic' || document.documentElement.dataset.theme !== 'classic' || select.value !== 'classic' || stored['ultimate-updater-theme'] !== 'classic') process.exit(2);
const safe = applyTheme('inject-me');
if (safe !== 'modern' || document.documentElement.dataset.theme !== 'modern' || select.value !== 'modern') process.exit(3);
console.log('web theme behavior: PASS');
"""
result = subprocess.run(["node", "-e", node_script], check=False, capture_output=True, text=True)
assert result.returncode == 0, result.stderr or result.stdout
assert "web theme behavior: PASS" in result.stdout

print("web theme tests: PASS")
