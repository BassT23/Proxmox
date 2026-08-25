#!/usr/bin/env python3
"""Regression tests for scheduler validation, persistence, and timer units."""

import importlib.util
import json
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

base = {
    "id": "0123456789ab",
    "name": "Nightly check",
    "type": "check-all",
    "frequency": "daily",
    "day": "",
    "time": "03:00",
    "enabled": True,
}

assert server.scheduler_validate(base, base["id"]) == base
assert server.scheduler_calendar(base) == "*-*-* 03:00:00"
weekly = {**base, "frequency": "weekly", "day": "Sunday", "time": "04:05"}
assert server.scheduler_calendar(weekly) == "Sun *-*-* 04:05:00"
assert server.scheduler_validate({**weekly, "type": "update-all"}, base["id"])["type"] == "update-all"

for invalid in (
    {**base, "time": "25:00"},
    {**base, "type": "check-one"},
    {**base, "frequency": "weekly", "day": "Someday"},
    {**base, "name": "bad\nname"},
):
    try:
        server.scheduler_validate(invalid, base["id"])
    except ValueError:
        pass
    else:
        raise AssertionError(f"invalid schedule accepted: {invalid}")

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "schedules.json"
    server.scheduler_save(path, [base])
    assert server.scheduler_load(path) == [base]
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert raw["schema_version"] == 1
    assert ";" not in server.scheduler_unit_files(base, Path(directory), Path("/usr/local/sbin/ultimate-updater"))[3]
    assert "OnCalendar=*-*-* 03:00:00" in server.scheduler_unit_files(base, Path(directory), Path("/usr/local/sbin/ultimate-updater"))[4]

print("scheduler tests: PASS")
