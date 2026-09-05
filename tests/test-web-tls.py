#!/usr/bin/env python3
"""TLS selection and safe fallback regression checks."""

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


old = {key: os.environ.get(key) for key in ("WEB_UI_HTTPS", "WEB_UI_CERT_FILE", "WEB_UI_KEY_FILE")}
try:
    os.environ["WEB_UI_HTTPS"] = "false"
    os.environ.pop("WEB_UI_CERT_FILE", None)
    os.environ.pop("WEB_UI_KEY_FILE", None)
    context, source, cert, reason = server.build_tls_context()
    assert context is None and source == "disabled" and cert is None

    with tempfile.TemporaryDirectory() as directory:
        os.environ["WEB_UI_HTTPS"] = "true"
        os.environ["WEB_UI_CERT_FILE"] = str(Path(directory) / "missing.pem")
        os.environ["WEB_UI_KEY_FILE"] = str(Path(directory) / "missing.key")
        try:
            server.build_tls_context()
        except server.TLSConfigurationError as error:
            assert "HTTPS requested but unavailable" in str(error)
        else:
            raise AssertionError("invalid required TLS configuration was accepted")
finally:
    for key, value in old.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

print("Web UI TLS selection tests: PASS")
