#!/usr/bin/env python3
"""Regression coverage for the local API v1 token administration boundary."""

import json
from pathlib import Path
import stat
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "web-ui"))
import api_tokens  # noqa: E402


with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary) / "api-tokens.json"
    token_id, secret = api_tokens.create_token(path, "fixture", ["read", "logs"])
    data = json.loads(path.read_text(encoding="utf-8"))
    assert token_id and secret not in path.read_text(encoding="utf-8")
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert api_tokens.authenticate(path, secret) is None
    api_tokens.set_enabled(path, True)
    identity = api_tokens.authenticate(path, secret)
    assert identity["id"] == token_id and identity["permissions"] == ["read", "logs"]
    api_tokens.revoke_token(path, token_id)
    assert api_tokens.authenticate(path, secret) is None

    link_target = Path(temporary) / "real.json"
    link_target.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
    link_target.chmod(0o600)
    path.unlink()
    path.symlink_to(link_target)
    try:
        api_tokens.load_config(path)
        raise AssertionError("symlink configuration was accepted")
    except api_tokens.TokenConfigError:
        pass

print("API token store tests: PASS")
