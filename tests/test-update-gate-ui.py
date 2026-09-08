#!/usr/bin/env python3
"""Static regression checks for the WebUI update soft/hard gate."""

from pathlib import Path


source = (Path(__file__).parents[1] / "web-ui" / "server.py").read_text(encoding="utf-8")

assert "function updateGate(t)" in source
assert "status==='error'" in source
assert "status==='stale'||t?.check_stale===true" in source
assert "t?.reachable===false||status==='offline'" in source
assert "status==='unsupported'||t?.updateable===false" in source
assert "if(running(t?.id))return{enabled:false" in source
assert "No successful check is available for this target." in source
assert "The last check for this target failed." in source
assert "The last successful check may be outdated." in source
assert "Continue with the update anyway?" in source
assert "b.disabled=!gate.enabled" in source
assert "{warning:gate.warning}" in source
assert "The backend update action remains unchanged" not in source

print("update gate UI tests: PASS")
