#!/usr/bin/env python3
"""Isolated origin and trusted reverse-proxy validation checks."""

from email.message import Message
import ipaddress
from pathlib import Path
import sys
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).parents[1] / "web-ui"))
import server  # noqa: E402


def handler(headers, source="127.0.0.1", public_origin=None, trusted=None, tls=False):
    message = Message()
    for name, value in headers:
        message.add_header(name, value)
    instance = object.__new__(server.StatusHandler)
    instance.headers = message
    instance.client_address = (source, 4321)
    instance.server = SimpleNamespace(
        public_origin=public_origin,
        trusted_proxy_networks=tuple(trusted or ()),
        tls_enabled=tls,
    )
    return instance


trusted = (ipaddress.ip_network("127.0.0.1/32"),)

# Direct mode remains strict and does not trust client-supplied forwarding data.
direct = handler([
    ("Host", "node.example.test:8765"),
    ("Origin", "http://node.example.test:8765"),
    ("X-Forwarded-Host", "attacker.example"),
    ("X-Forwarded-Proto", "https"),
], source="198.51.100.20")
assert direct.same_origin() is True
assert direct.request_is_secure() is False
assert direct.proxmox_request_context() == ("node.example.test:8765", "http://node.example.test:8765")
assert handler([
    ("Host", "node.example.test:8765"),
    ("Origin", "https://attacker.example"),
], source="198.51.100.20").same_origin() is False

# Trusted X-Forwarded-* headers establish the public context only for the
# configured proxy source and only as an unambiguous pair.
forwarded = handler([
    ("Host", "127.0.0.1:8765"),
    ("X-Forwarded-Host", "ui.example.test"),
    ("X-Forwarded-Proto", "https"),
    ("Origin", "https://ui.example.test"),
], trusted=trusted)
assert forwarded.same_origin() is True
assert forwarded.request_is_secure() is True
assert forwarded.proxmox_request_context() == ("ui.example.test", "https://ui.example.test")

untrusted_forwarded = handler([
    ("Host", "127.0.0.1:8765"),
    ("X-Forwarded-Host", "ui.example.test"),
    ("X-Forwarded-Proto", "https"),
    ("Origin", "https://ui.example.test"),
], source="198.51.100.20", trusted=trusted)
assert untrusted_forwarded.same_origin() is False

for headers in (
    [("Host", "127.0.0.1:8765"), ("X-Forwarded-Host", "ui.example.test"),
     ("X-Forwarded-Host", "other.example"), ("X-Forwarded-Proto", "https"),
     ("Origin", "https://ui.example.test")],
    [("Host", "127.0.0.1:8765"), ("Forwarded", "proto=https;host=ui.example.test"),
     ("X-Forwarded-Host", "ui.example.test"), ("Origin", "https://ui.example.test")],
    [("Host", "127.0.0.1:8765"), ("Forwarded", "proto=https;host=ui.example.test,proto=https;host=other.example"),
     ("Origin", "https://ui.example.test")],
    [("Host", "127.0.0.1:8765"), ("X-Forwarded-Host", "ui.example.test"),
     ("X-Forwarded-Proto", "ftp"), ("Origin", "https://ui.example.test")],
):
    assert handler(headers, trusted=trusted).same_origin() is False

forwarded_header = handler([
    ("Host", "127.0.0.1:8765"),
    ("Forwarded", "for=198.51.100.20;proto=https;host=ui.example.test"),
    ("Origin", "https://ui.example.test"),
], trusted=trusted)
assert forwarded_header.same_origin() is True
assert forwarded_header.proxmox_request_context() == ("ui.example.test", "https://ui.example.test")

# Explicit public origin mode is authoritative and still requires a trusted
# proxy source. Forwarded values, when present, must agree with it.
explicit = handler([
    ("Host", "127.0.0.1:8765"),
    ("Origin", "https://ui.example.test"),
], public_origin="https://ui.example.test", trusted=trusted)
assert explicit.same_origin() is True
assert explicit.proxmox_request_context() == ("ui.example.test", "https://ui.example.test")
assert explicit.request_is_secure() is True
assert handler([
    ("Host", "127.0.0.1:8765"),
    ("X-Forwarded-Host", "other.example"),
    ("X-Forwarded-Proto", "https"),
    ("Origin", "https://ui.example.test"),
], public_origin="https://ui.example.test", trusted=trusted).same_origin() is False
assert handler([
    ("Host", "127.0.0.1:8765"),
    ("Origin", "https://ui.example.test"),
], source="198.51.100.20", public_origin="https://ui.example.test", trusted=trusted).same_origin() is False
port_specific = handler([
    ("Host", "127.0.0.1:8765"),
    ("Origin", "https://ui.example.test:8443"),
], public_origin="https://ui.example.test:8443", trusted=trusted)
assert port_specific.same_origin() is True
assert handler([
    ("Host", "127.0.0.1:8765"),
    ("Origin", "https://ui.example.test"),
], public_origin="https://ui.example.test:8443", trusted=trusted).same_origin() is False

# Duplicate Origin and malformed configuration fail closed.
assert handler([
    ("Host", "node.example.test"),
    ("Origin", "http://node.example.test"),
    ("Origin", "http://node.example.test"),
]).same_origin() is False
assert server.parse_public_origin("https://ui.example.test") == "https://ui.example.test"
for invalid in ("https://*.example.test", "https://ui.example.test/path", "https://ui.example.test:0", "ftp://ui.example.test"):
    try:
        server.parse_public_origin(invalid)
    except server.ProxyConfigurationError:
        pass
    else:
        raise AssertionError(f"invalid public origin accepted: {invalid}")
for invalid in ("proxy.example.test", "127.0.0.1/32,,::1/128", "127.0.0.1/999", "0.0.0.0/0"):
    try:
        server.parse_trusted_proxy_cidrs(invalid)
    except server.ProxyConfigurationError:
        pass
    else:
        raise AssertionError(f"invalid trusted proxy accepted: {invalid}")
try:
    old_public = server.os.environ.get(server.WEB_UI_PUBLIC_ORIGIN_ENV)
    old_trusted = server.os.environ.get(server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV)
    server.os.environ[server.WEB_UI_PUBLIC_ORIGIN_ENV] = "https://ui.example.test"
    server.os.environ.pop(server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV, None)
    try:
        server.load_proxy_configuration()
    except server.ProxyConfigurationError:
        pass
    else:
        raise AssertionError("public origin without trusted proxy was accepted")
finally:
    if old_public is None:
        server.os.environ.pop(server.WEB_UI_PUBLIC_ORIGIN_ENV, None)
    else:
        server.os.environ[server.WEB_UI_PUBLIC_ORIGIN_ENV] = old_public
    if old_trusted is None:
        server.os.environ.pop(server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV, None)
    else:
        server.os.environ[server.WEB_UI_TRUSTED_PROXY_CIDRS_ENV] = old_trusted

print("reverse-proxy origin tests: PASS")
