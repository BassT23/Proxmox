#!/usr/bin/env python3
"""Regression coverage for scheduler schema, selection, and timer units."""

import importlib.util
import json
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ultimate_updater_web", root / "web-ui" / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)

base = {
    "id": "0123456789ab", "name": "Nightly check", "type": "check-all",
    "days": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
    "time": "03:00", "enabled": True, "targets": [],
}
assert server.scheduler_validate(base, base["id"]) == base
assert server.scheduler_calendar(base) == "*-*-* 03:00:00"
single = {**base, "days": ["Sun"], "time": "04:05"}
assert server.scheduler_calendar(single) == "Sun *-*-* 04:05:00"
multiple = {**base, "days": ["Mon", "Wed", "Fri"]}
assert server.scheduler_calendar(multiple) == "Mon,Wed,Fri *-*-* 03:00:00"
selected = {**base, "type": "check-selected", "targets": ["host:node1", "101"]}
assert server.scheduler_validate(selected, base["id"])["targets"] == ["host:node1", "101"]
assert server.scheduler_commands(selected, Path("/usr/local/sbin/ultimate-updater")) == [
    ["/usr/local/sbin/ultimate-updater", "check", "node1"],
    ["/usr/local/sbin/ultimate-updater", "check", "101"],
]
assert server.scheduler_validate({**selected, "type": "update-selected"}, base["id"])["type"] == "update-selected"

legacy_daily = {"id": base["id"], "name": base["name"], "type": "check-all",
                "frequency": "daily", "day": "", "time": "03:00", "enabled": True}
assert server.scheduler_validate(legacy_daily, base["id"])["days"] == list(server.SCHEDULER_DAYS)
legacy_weekly = {**legacy_daily, "frequency": "weekly", "day": "Monday"}
assert server.scheduler_validate(legacy_weekly, base["id"])["days"] == ["Mon"]

for invalid in (
    {**base, "time": "25:00"},
    {**base, "type": "check-one"},
    {**base, "days": []},
    {**base, "days": ["Someday"]},
    {**base, "name": "bad\nname"},
    {**base, "type": "check-selected", "targets": []},
    {**base, "targets": ["bad target"]},
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
    assert raw["schema_version"] == 2
    server.scheduler_save(path, [single])
    assert path.with_name("schedules.json.bak").exists()
    service = server.scheduler_unit_files(selected, Path(directory), Path("/usr/local/sbin/ultimate-updater"))[3]
    timer = server.scheduler_unit_files(multiple, Path(directory), Path("/usr/local/sbin/ultimate-updater"))[4]
    assert "ExecStart=/usr/local/sbin/ultimate-updater check node1" in service
    assert "ExecStart=/usr/local/sbin/ultimate-updater check 101" in service
    assert "OnCalendar=Mon,Wed,Fri *-*-* 03:00:00" in timer
    assert ";" not in service

print("scheduler tests: PASS")
