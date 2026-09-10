#!/usr/bin/env python3
"""Validation and persistence checks for the optional internal selection."""

import json
import tempfile
from pathlib import Path
import sys

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


valid = {"schema_version": 1, "check": {"host:node1": "only", "200": "exclude"},
         "update": {"external:backup": "only"}}
assert server.validate_target_selection(valid) == valid
for invalid in (
    {"schema_version": 2},
    {"schema_version": 1, "check": {"200": "invalid"}},
    {"schema_version": 1, "check": {"bad id": "only"}},
):
    try:
        server.validate_target_selection(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError(invalid)

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "target-selection.json"
    server.write_target_selection(path, valid)
    assert json.loads(path.read_text(encoding="utf-8")) == valid
    assert path.stat().st_mode & 0o777 == 0o600
    assert server.read_target_selection(path) == valid

print("target selection validation tests: PASS")
