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

    before = path.read_bytes()
    assert server.read_target_selection(path) == valid
    assert path.read_bytes() == before

    invalid = Path(directory) / "invalid-target-selection.json"
    invalid.write_text('{"schema_version":1,"check":{"guest:910":"broken"}}\n', encoding="utf-8")
    invalid_before = invalid.read_bytes()
    assert server.read_target_selection(invalid) == server.target_selection_default()
    try:
        server.read_target_selection_for_api(invalid)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
        pass
    else:
        raise AssertionError("strict API read must reject invalid persisted selection")
    assert invalid.read_bytes() == invalid_before

print("target selection validation tests: PASS")
