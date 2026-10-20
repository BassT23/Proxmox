#!/usr/bin/env python3
"""Local negative/positive checks for trusted reverse-proxy WebUI sessions."""

from email.message import Message
import importlib.util
import ipaddress
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile


ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("ultimate_updater_trusted_proxy", ROOT / "web-ui" / "server.py")
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


ASSERTION = "A9f4K2m7Qx8Vn3Lp6Rz1Tg5Yw0Hs4Dc8Jk2Pb7Ne6Ua3"
TRUSTED = (ipaddress.ip_network("127.0.0.1/32"),)


def headers(items):
    message = Message()
    for name, value in items:
        message.add_header(name, value)
    return message


def request(auth, config, items, source="127.0.0.1"):
    instance = object.__new__(server.StatusHandler)
    instance.headers = headers(items)
    instance.client_address = (source, 12345)
    instance.server = SimpleNamespace(
        auth=auth,
        trusted_proxy_auth=config,
        trusted_proxy_networks=TRUSTED,
        public_origin="https://ui.example.test",
        tls_enabled=False,
    )
    return instance


def config(assertion_file):
    return {
        "enabled": True,
        "identity_header": "Remote-User",
        "identities": frozenset({"uu-operator@example.invalid"}),
        "assertion_file": assertion_file,
        "assertion_header": server.WEB_UI_TRUSTED_AUTH_ASSERTION_HEADER,
    }


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    assertion_file = root / "gateway-assertion"
    assertion_file.write_text(ASSERTION + "\n", encoding="ascii")
    os.chmod(assertion_file, 0o600)

    # Disabled is the safe default and does not require any proxy secret.
    saved = {key: os.environ.get(key) for key in (
        server.WEB_UI_TRUSTED_AUTH_ENABLED_ENV,
        server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV,
        server.WEB_UI_TRUSTED_AUTH_IDENTITY_HEADER_ENV,
        server.WEB_UI_TRUSTED_AUTH_IDENTITIES_ENV,
        server.WEB_UI_TRUSTED_AUTH_ASSERTION_FILE_ENV,
    )}
    try:
        for key in saved:
            os.environ.pop(key, None)
        assert server.load_trusted_proxy_auth_configuration(()) == {"enabled": False}

        os.environ[server.WEB_UI_TRUSTED_AUTH_ENABLED_ENV] = "true"
        os.environ[server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV] = "127.0.0.1/32"
        os.environ[server.WEB_UI_TRUSTED_AUTH_IDENTITIES_ENV] = "uu-operator@example.invalid"
        os.environ[server.WEB_UI_TRUSTED_AUTH_ASSERTION_FILE_ENV] = str(assertion_file)
        loaded = server.load_trusted_proxy_auth_configuration(TRUSTED)
        assert loaded["enabled"] is True
        assert loaded["identity_header"] == "Remote-User"
        assert loaded["identities"] == frozenset({"uu-operator@example.invalid"})

        auth = server.AuthStore(root / "web-auth.json")
        valid_items = [
            ("Host", "127.0.0.1:8765"),
            ("Origin", "https://ui.example.test"),
            ("Remote-User", "uu-operator@example.invalid"),
            (server.WEB_UI_TRUSTED_AUTH_ASSERTION_HEADER, ASSERTION),
        ]
        first = request(auth, loaded, valid_items)
        session = first.current_session()
        assert session["auth_method"] == "trusted-proxy"
        assert session["proxy_identity"] == "uu-operator@example.invalid"
        assert first._response_cookies and "UU_SESSION=" in first._response_cookies[0]
        cookie = first._response_cookies[0].split(";", 1)[0]
        csrf = session["csrf"]

        # The same gateway identity revalidates the existing session and can
        # pass the ordinary Origin/CSRF write gate.
        second = request(auth, loaded, valid_items + [("Cookie", cookie), ("X-CSRF-Token", csrf)])
        assert second.current_session()["proxy_identity"] == "uu-operator@example.invalid"
        second.send_json = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("unexpected rejection"))
        assert second.write_allowed() is True
        assert second.logout_allowed() == cookie.split("=", 1)[1]

        auth.sessions[cookie.split("=", 1)[1]]["expires"] = 0
        refreshed = request(auth, loaded, valid_items + [("Cookie", cookie)])
        assert refreshed.current_session()["proxy_identity"] == "uu-operator@example.invalid"
        assert refreshed._response_cookies

        # Identity changes, missing proof, and a direct backend request do not
        # reuse the proxy session.
        changed = request(auth, loaded, [
            ("Cookie", cookie), ("Remote-User", "other@example.invalid"),
            (server.WEB_UI_TRUSTED_AUTH_ASSERTION_HEADER, ASSERTION),
        ])
        assert changed.current_session() is None
        assert changed._trusted_proxy_error
        direct = request(auth, loaded, [("Cookie", cookie)])
        assert direct.current_session() is None
        forwarded_spoof = request(auth, loaded, valid_items + [("X-Forwarded-For", "127.0.0.1")],
                                  source="198.51.100.20")
        assert forwarded_spoof.current_session() is None
        assert forwarded_spoof._trusted_proxy_error

        # Exact-once header and exact allowlist enforcement.
        for bad_items in (
            valid_items + [("Remote-User", "uu-operator@example.invalid")],
            [*valid_items[:-2], ("Remote-User", "not-allowlisted"), valid_items[-1]],
            valid_items[:-1] + [(server.WEB_UI_TRUSTED_AUTH_ASSERTION_HEADER, "wrong")],
            valid_items[:-1],
        ):
            bad = request(auth, loaded, bad_items)
            assert bad.current_session() is None
            assert bad._trusted_proxy_error

        # A native session remains usable while the feature is disabled.
        auth.backend = "internal"
        native_token = "native-session"
        auth.sessions[native_token] = {"user": "admin@pam", "csrf": "native-csrf",
                                       "expires": 2**31}
        disabled = request(auth, {"enabled": False}, [("Cookie", f"UU_SESSION={native_token}")])
        assert disabled.current_session()["user"] == "admin@pam"

        for key, value in (
            (server.WEB_UI_TRUSTED_AUTH_IDENTITY_HEADER_ENV, "Authorization"),
            (server.WEB_UI_TRUSTED_AUTH_IDENTITY_HEADER_ENV, "Remote User"),
            (server.WEB_UI_TRUSTED_AUTH_IDENTITIES_ENV, ""),
            (server.WEB_UI_TRUSTED_AUTH_IDENTITIES_ENV, "one,one"),
        ):
            os.environ[server.WEB_UI_TRUSTED_AUTH_IDENTITY_HEADER_ENV] = "Remote-User"
            os.environ[server.WEB_UI_TRUSTED_AUTH_IDENTITIES_ENV] = "uu-operator@example.invalid"
            os.environ[key] = value
            try:
                server.load_trusted_proxy_auth_configuration(TRUSTED)
            except server.TrustedProxyAuthError:
                pass
            else:
                raise AssertionError(f"invalid proxy configuration accepted: {key}={value}")

        # Missing, symlinked, malformed, or world-readable assertion files are
        # configuration failures, not reasons to relax the proxy gate.
        for mutation in ("missing", "symlink", "mode", "owner"):
            candidate = root / f"assertion-{mutation}"
            if mutation == "missing":
                pass
            elif mutation == "symlink":
                candidate.symlink_to(assertion_file)
            elif mutation == "mode":
                candidate.write_text(ASSERTION, encoding="ascii")
                os.chmod(candidate, 0o640)
            else:
                if os.geteuid() != 0:
                    continue
                candidate.write_text(ASSERTION, encoding="ascii")
                os.chmod(candidate, 0o600)
                os.chown(candidate, 65534, 65534)
            try:
                server._read_gateway_assertion(candidate)
            except server.TrustedProxyAuthError:
                pass
            else:
                raise AssertionError(f"unsafe assertion accepted: {mutation}")
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

print("trusted reverse-proxy auth tests: PASS")
