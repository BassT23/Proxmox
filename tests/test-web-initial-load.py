#!/usr/bin/env python3
"""Regression coverage for the non-blocking initial Systems data load."""

import importlib.util
import re
import subprocess
import tempfile
from html.parser import HTMLParser
from pathlib import Path


root = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = (root / "web-ui/server.py").read_text(encoding="utf-8")

assert 'id="system-data-loading"' in module.PAGE
assert 'role="status"' in module.PAGE
assert 'aria-live="polite"' in module.PAGE
assert 'Loading system inventory and status…' in module.PAGE
assert 'system-data-loading-spinner" aria-hidden="true"' in module.PAGE
assert 'function beginInitialSystemDataLoad' in source
assert "completeInitialSystemDataPart('inventory',generation)" in source
assert "completeInitialSystemDataPart('status',generation)" in source
assert "finally{completeInitialSystemDataPart('inventory',generation);completeInitialSystemDataPart('status',generation)}" in source
assert 'function resetInitialSystemDataLoading' in source
assert 'html[data-theme="classic"] .system-data-loading' in module.PAGE
assert 'setTimeout' not in source[source.index('function updateInitialSystemDataLoading'):source.index('function resetInitialSystemDataLoading')]


class InlineScripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            self.scripts.append("".join(self.current))
            self.current = None


parser = InlineScripts()
parser.feed(module.PAGE)
assert any("async function ensureSession" in script for script in parser.scripts)
assert any("bootstrap();" in script for script in parser.scripts)
ensure_script = next(index for index, script in enumerate(parser.scripts) if "async function ensureSession" in script)
bootstrap_script = next(index for index, script in enumerate(parser.scripts) if "bootstrap();" in script)
assert ensure_script < bootstrap_script
with tempfile.TemporaryDirectory() as directory:
    for index, script in enumerate(parser.scripts, 1):
        path = Path(directory) / f"web-ui-script-{index}.js"
        path.write_text(script, encoding="utf-8")
        result = subprocess.run(["node", "--check", str(path)], check=False, capture_output=True, text=True)
        assert result.returncode == 0, f"script {index}: {result.stderr or result.stdout}"

helpers = re.search(
    r"function updateInitialSystemDataLoading\(\).*?function resetInitialSystemDataLoading\(\).*?updateInitialSystemDataLoading\(\)\}",
    source,
    flags=re.S,
).group(0)
node_script = f"""
let authGeneration = 7;
const indicator = {{hidden: true}};
const document = {{getElementById: id => id === 'system-data-loading' ? indicator : null}};
{helpers}
beginInitialSystemDataLoad();
if (indicator.hidden) process.exit(1);
completeInitialSystemDataPart('inventory');
if (indicator.hidden) process.exit(2);
completeInitialSystemDataPart('status');
if (!indicator.hidden) process.exit(3);
beginInitialSystemDataLoad();
completeInitialSystemDataPart('status');
if (indicator.hidden) process.exit(4);
completeInitialSystemDataPart('inventory');
if (!indicator.hidden) process.exit(5);
console.log('web initial load state: PASS');
"""
result = subprocess.run(["node", "-e", node_script], check=False, capture_output=True, text=True)
assert result.returncode == 0, result.stderr or result.stdout
assert "web initial load state: PASS" in result.stdout

print("web initial load tests: PASS")
