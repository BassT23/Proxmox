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
