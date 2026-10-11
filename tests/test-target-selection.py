#!/usr/bin/env python3
"""Validation and persistence checks for the optional internal selection."""

import json
import tempfile
from pathlib import Path
import sys
from types import SimpleNamespace

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

    missing = Path(directory) / "missing-target-selection.json"
    assert server.ensure_target_selection_file(missing) is True
    assert json.loads(missing.read_text(encoding="utf-8")) == server.target_selection_default()
    assert missing.stat().st_mode & 0o777 == 0o600
    missing_before = missing.read_bytes()
    assert server.ensure_target_selection_file(missing) is False
    assert missing.read_bytes() == missing_before

    config = Path(directory) / "update.conf"
    config.write_text('USE_INTERNAL_TARGET_SELECTION="false"\nDEBUG="false"\n', encoding="utf-8")
    activation_handler = object.__new__(server.StatusHandler)
    activation_handler.server = SimpleNamespace(config_file=config, target_selection_file=missing)
    activation_handler.responses = []
    activation_handler.config_content = lambda: config.read_text(encoding="utf-8")
    activation_handler.send_json = lambda payload: activation_handler.responses.append(payload)
    missing.unlink()
    server.StatusHandler.handle_config_update(activation_handler, {"values": {"USE_INTERNAL_TARGET_SELECTION": True}})
    assert json.loads(missing.read_text(encoding="utf-8")) == server.target_selection_default()
    assert 'USE_INTERNAL_TARGET_SELECTION="true"' in config.read_text(encoding="utf-8")
    assert activation_handler.responses[-1]["message"] == "Configuration saved."

    selected = {"schema_version": 1, "check": {"host:node1": "only"}, "update": {}}
    server.write_target_selection(missing, selected)
    selected_before = missing.read_bytes()
    server.StatusHandler.handle_config_update(activation_handler, {"values": {"DEBUG": True}})
    assert missing.read_bytes() == selected_before

print("target selection validation tests: PASS")
