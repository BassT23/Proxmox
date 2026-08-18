#!/usr/bin/env python3
"""Static regression checks for bounded live logs and full-log downloads."""

from pathlib import Path

root = Path(__file__).parents[1]
source = (root / "web-ui" / "server.py").read_text(encoding="utf-8")
runner = (root / "job-runner.sh").read_text(encoding="utf-8")

assert "/api/jobs/${encodeURIComponent(j.unit)}/download" in source
assert "Content-Disposition" in source
assert "JOB_RE.fullmatch(unit)" in source
assert '"journalctl", "-u", unit, "--no-pager", "-o", "cat"' in source
assert '"Full log is no longer available."' in source
assert "remote-log-full" in source
assert "journalctl -u %q --no-pager -o cat" in runner
assert "logAutoFollow" in source
assert "dataset.scrollAttached==='true'" in source
assert "Jump to latest" in source
assert "logScrollTop" in source

print("job log UI/download tests: PASS")
