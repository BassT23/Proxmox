"""Static safety coverage for the target-detail reboot action."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
server = (ROOT / "web-ui" / "server.py").read_text(encoding="utf-8")
runner = (ROOT / "job-runner.sh").read_text(encoding="utf-8")

assert "POST /api/targets/<target>/reboot" not in server  # no documentation-only fake route
assert 'parts[3] == "reboot"' in server
assert "def action_reboot(self, target_id)" in server
assert 'kind not in {"host", "lxc", "vm"}' in server
assert 'target.get("reboot_required") is not True' in server
assert 'target.get("reachable") is not True' in server
assert '"start-reboot"' in server
assert "rebootTargetSupported(t)" in server
assert "t.reboot_required===true" in server
assert "Reboot now" in server
assert "Running guests on this node may be affected." in server
assert "Confirm node reboot" in server
assert "The system will be restarted." in server
assert "targetRow(t)" in server
assert "data-reboot-target" not in server.split("function targetRow(t)", 1)[1].split("document.getElementById('config-open')", 1)[0]

assert "REBOOT_PREFIX=\"ultimate-updater-reboot-\"" in runner
assert "start-reboot)" in runner
assert "run-reboot)" in runner
assert '[[ "$kind" == host || "$kind" == lxc || "$kind" == vm ]]' in runner
assert "running_job_conflict" in runner
assert 'remote_command="pct reboot $target"' in runner
assert 'remote_command="qm reboot $target"' in runner
assert "systemctl reboot" in runner
assert '"Reboot initiated"' in runner
