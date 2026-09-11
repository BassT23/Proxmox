#!/usr/bin/env python3
"""Static regression contract for the running/final job output lifecycle."""

import importlib.util
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_web", ROOT / "web-ui" / "server.py")
WEB = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(WEB)


def main():
    page = WEB.PAGE
    scripts = re.findall(r"<script(?:\s[^>]*)?>(.*?)</script>", page, re.S | re.I)
    assert any("const showFinalOutput=" in script for script in scripts)
    assert "Final output" in page
    assert "const finalJobState=job=>job?.state&&job.state!=='running'" in page
    assert "state.mode='final'" in page
    assert "state.eventSource.close()" in page
    assert "finalOutputLoaded.has(state.unit)||finalOutputLoading.has(state.unit)" in page
    assert "state.terminal.reset();state.terminal.write" in page
    assert "interactiveKeybarVisibility(false)" in page
    assert "if(finalJobState(job))void showFinalOutput(state,job)" in page
    assert "if(state.finalizing)return" in page
    assert "if(job.interactive)void openInteractiveTerminal(job.unit);else void openLiveOutput(job.unit)" in page
    assert "const openInteractiveTerminal=async unit=>{const job=jobs.find(item=>item.unit===unit);if(finalJobState(job))return" in page
    assert "const openLiveOutput=async unit=>{const job=jobs.find(item=>item.unit===unit);if(finalJobState(job))return" in page
    print("job output lifecycle contract: PASS")


if __name__ == "__main__":
    main()
