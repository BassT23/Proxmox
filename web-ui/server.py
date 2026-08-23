#!/usr/bin/env python3
"""Small standard-library web UI for status and session-independent actions."""

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import shlex
import stat
import ssl
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

try:
    from pam_auth import authenticate as pam_authenticate
except ImportError:  # pragma: no cover - direct installed-script fallback
    pam_authenticate = None


DEFAULT_STATUS_FILE = Path("/etc/ultimate-updater/status.json")

ANSI_ESCAPE_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")


def strip_ansi(text):
    return ANSI_ESCAPE_RE.sub("", text)
DEFAULT_CONFIG_FILE = Path("/etc/ultimate-updater/update.conf")
DEFAULT_INVENTORY_FILE = Path("/etc/ultimate-updater/targets.conf")
DEFAULT_INVENTORY_SCRIPT = Path("/etc/ultimate-updater/target-inventory.sh")
DEFAULT_TAG_FILTER = Path("/etc/ultimate-updater/tag-filter.sh")
DEFAULT_EXTERNAL_SCRIPT = Path("/etc/ultimate-updater/external-apt.sh")
DEFAULT_EXTERNAL_SETTINGS_SCRIPT = Path("/etc/ultimate-updater/external-settings.sh")
DEFAULT_ASSET_DIR = Path("/etc/ultimate-updater/web-ui/assets")
DEFAULT_CLI = Path("/usr/local/sbin/ultimate-updater")
DEFAULT_UPDATE_SCRIPT = Path("/etc/ultimate-updater/update.sh")
DEFAULT_JOB_RUNNER = Path("/etc/ultimate-updater/job-runner.sh")
DEFAULT_JOBS_DIR = Path("/var/lib/ultimate-updater/jobs")
VISIBLE_JOB_LIMIT = 20
DEFAULT_BACKUP_STATE_FILE = Path("/var/lib/ultimate-updater/external-backup-verification.json")
DEFAULT_AUTH_FILE = Path("/etc/ultimate-updater/web-auth.json")
DEFAULT_INTERNAL_SSH_FILE = Path("/etc/ultimate-updater/internal-ssh.conf")
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_PROXMOX_CERT = Path("/etc/pve/local/pve-ssl.pem")
DEFAULT_PROXMOX_KEY = Path("/etc/pve/local/pve-ssl.key")
DEFAULT_PROXMOX_CUSTOM_CERT = Path("/etc/pve/local/pveproxy-ssl.pem")
DEFAULT_PROXMOX_CUSTOM_KEY = Path("/etc/pve/local/pveproxy-ssl.key")
TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
JOB_RE = re.compile(r"^ultimate-updater-(?:update|check)-[A-Za-z0-9_.-]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")
INTERNAL_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")


class TLSConfigurationError(RuntimeError):
    """Raised when explicitly requested WebUI TLS cannot be initialized."""


def _tls_mode():
    mode = os.environ.get("WEB_UI_HTTPS", "auto").strip().lower()
    if mode in {"1", "yes", "on", "true"}:
        return "required"
    if mode in {"0", "no", "off", "false"}:
        return "disabled"
    if mode == "auto":
        return mode
    raise TLSConfigurationError(
        "WEB_UI_HTTPS must be auto, true, or false (received: %s)" % mode
    )


def build_tls_context():
    """Return (SSL context, source, certificate path, fallback reason).

    Certificate files are referenced in place.  No private key is copied or
    permission-adjusted; the service already runs as root for the updater CLI.
    """
    mode = _tls_mode()
    if mode == "disabled":
        return None, "disabled", None, "HTTPS disabled by configuration"

    configured_cert = os.environ.get("WEB_UI_CERT_FILE", "").strip()
    configured_key = os.environ.get("WEB_UI_KEY_FILE", "").strip()
    custom_configured = bool(configured_cert or configured_key)
    if custom_configured:
        if not configured_cert or not configured_key:
            message = "WEB_UI_CERT_FILE and WEB_UI_KEY_FILE must be configured together"
            if mode == "required":
                raise TLSConfigurationError(message)
            raise TLSConfigurationError(message)
        candidates = [(Path(configured_cert), Path(configured_key), "custom")]
    else:
        # pveproxy prefers the custom pair when present and otherwise uses the
        # node certificate pair.  Use the same priority without copying files.
        candidates = [
            (DEFAULT_PROXMOX_CUSTOM_CERT, DEFAULT_PROXMOX_CUSTOM_KEY, "Proxmox custom"),
            (DEFAULT_PROXMOX_CERT, DEFAULT_PROXMOX_KEY, "Proxmox"),
        ]

    failures = []
    for cert_file, key_file, source in candidates:
        if not cert_file.is_file() or not key_file.is_file():
            failures.append(f"missing certificate/key pair: {cert_file} / {key_file}")
            continue
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        try:
            context.load_cert_chain(certfile=str(cert_file), keyfile=str(key_file))
        except (OSError, ssl.SSLError) as error:
            failures.append(f"could not load {cert_file}: {error}")
            continue
        return context, source, cert_file, ""

    reason = "; ".join(failures) or "no certificate/key pair configured"
    if mode == "required":
        raise TLSConfigurationError(f"HTTPS requested but unavailable: {reason}")
    if custom_configured:
        raise TLSConfigurationError(f"Configured WebUI HTTPS certificate is invalid: {reason}")
    return None, "HTTP fallback", None, reason

CONFIG_BOOLEAN_KEYS = {
    "CHECK_WITH_HOST", "CHECK_WITH_LXC", "CHECK_WITH_VM",
    "CHECK_RUNNING_CONTAINER", "CHECK_STOPPED_CONTAINER",
    "CHECK_RUNNING_VM", "CHECK_STOPPED_VM", "CHECK_PAUSED_VM",
    "WITH_HOST", "WITH_LXC", "WITH_VM", "RUNNING_CONTAINER",
    "STOPPED_CONTAINER", "RUNNING_VM", "STOPPED_VM",
    "REBOOT_IF_NEEDED", "EXIT_ON_ERROR", "DEBUG", "SNAPSHOT", "BACKUP",
    "BACKUP_LXC_MP", "EMAIL_DAILY_CHECK", "EMAIL_NO_UPDATES",
    "EMAIL_ONLY_SECURITY", "EMAIL_ONLY_ERROR", "VERSION_CHECK",
    "FREEBSD_UPDATES", "INCLUDE_PHASED_UPDATES", "INCLUDE_FSTRIM",
    "FSTRIM_WITH_MOUNTPOINT", "INCLUDE_HELPER_SCRIPTS", "EXTRA_GLOBAL",
    "IN_HEADLESS_MODE", "PIHOLE", "IOBROKER", "PTERODACTYL", "OCTOPRINT",
    "DOCKER_COMPOSE", "UNIFI",
}
CONFIG_INTEGER_KEYS = {"SSH_PORT", "LXC_START_DELAY", "VM_START_DELAY", "KEEP_SNAPSHOTS"}
CONFIG_STRING_KEYS = {
    "ONLY_UPDATE_CHECK", "EXCLUDE_UPDATE_CHECK", "ONLY", "EXCLUDE",
    "BACKUP_MODE", "BACKUP_STORAGE",
    "EMAIL_USER", "EMAIL_SENDER", "EXE_FOR_INTERNET_CHECK",
    "URL_FOR_INTERNET_CHECK", "PACMAN_ENVIRONMENT", "COMPOSE_PATH",
}
CONFIG_ENUMS = {"BACKUP_MODE": {"stop", "suspend", "snapshot"}}
CONFIG_KEYS = CONFIG_BOOLEAN_KEYS | CONFIG_INTEGER_KEYS | CONFIG_STRING_KEYS

# Every schema key has an explicit audit classification.  Internal and
# deprecated keys are intentionally not part of CONFIG_KEYS and therefore
# cannot be written through the Web UI.
CONFIG_KEY_CATEGORIES = {
    "VERSION": "internal", "USED_BRANCH": "internal", "DEBUG": "visible",
    "LOG_FILE": "internal", "ERROR_LOG_FILE": "internal",
    "VERSION_CHECK": "advanced", "SSH_PORT": "advanced",
    "EXE_FOR_INTERNET_CHECK": "advanced", "URL_FOR_INTERNET_CHECK": "advanced",
    "LXC_START_DELAY": "advanced", "VM_START_DELAY": "advanced",
    "EMAIL_USER": "visible", "EMAIL_SENDER": "visible",
    "EMAIL_DAILY_CHECK": "visible", "EMAIL_NO_UPDATES": "visible",
    "EMAIL_ONLY_SECURITY": "visible", "EMAIL_ONLY_ERROR": "visible",
    "CHECK_WITH_HOST": "visible", "CHECK_WITH_LXC": "visible", "CHECK_WITH_VM": "visible",
    "CHECK_STOPPED_CONTAINER": "visible", "CHECK_RUNNING_CONTAINER": "visible",
    "CHECK_STOPPED_VM": "visible", "CHECK_PAUSED_VM": "visible", "CHECK_RUNNING_VM": "visible",
    "ONLY_UPDATE_CHECK": "visible", "EXCLUDE_UPDATE_CHECK": "visible",
    "WITH_HOST": "visible", "WITH_LXC": "visible", "WITH_VM": "visible",
    "STOPPED_CONTAINER": "visible", "RUNNING_CONTAINER": "visible",
    "STOPPED_VM": "visible", "RUNNING_VM": "visible",
    "ONLY": "visible", "EXCLUDE": "visible", "EXIT_ON_ERROR": "visible",
    "REBOOT_IF_NEEDED": "visible", "SNAPSHOT": "visible", "KEEP_SNAPSHOTS": "visible",
    "BACKUP": "visible", "BACKUP_LXC_MP": "visible", "BACKUP_MODE": "visible",
    "BACKUP_STORAGE": "visible",
    "FREEBSD_UPDATES": "advanced", "INCLUDE_PHASED_UPDATES": "advanced",
    "INCLUDE_FSTRIM": "advanced", "FSTRIM_WITH_MOUNTPOINT": "advanced",
    "PACMAN_ENVIRONMENT": "advanced", "INCLUDE_HELPER_SCRIPTS": "advanced",
    "EXTRA_GLOBAL": "advanced", "IN_HEADLESS_MODE": "advanced",
    "PIHOLE": "advanced", "IOBROKER": "advanced", "PTERODACTYL": "advanced",
    "OCTOPRINT": "advanced", "DOCKER_COMPOSE": "advanced", "UNIFI": "advanced",
    "COMPOSE_PATH": "advanced",
    "INCLUDE_KERNEL": "deprecated",
}
UI_ASSETS = {
    "/assets/ultimate-updater-header.png": ("ultimate-updater-header.png", "image/png"),
    "/assets/ultimate-updater-icon.png": ("ultimate-updater-icon.png", "image/png"),
    "/assets/favicon.png": ("favicon.png", "image/png"),
}


PAGE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark"><link rel="icon" href="/assets/favicon.png" type="image/png"><title>Ultimate Updater</title>
  <style>
    :root { color-scheme:dark; --bg:#0b1020; --panel:#151d34e8; --strong:#19233f; --text:#edf3ff; --muted:#91a0bd; --line:#94a3b82e; --accent:#73a7ff; --good:#55d39a; --warn:#f7c66b; --security:#f0a83a; --bad:#ff7e8b; font-family:Inter,ui-sans-serif,system-ui,sans-serif; }
    * { box-sizing:border-box } .visually-hidden { position:absolute; width:1px; height:1px; padding:0; margin:-1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0 } body { margin:0; min-height:100vh; color:var(--text); background:radial-gradient(circle at top right,#1e3567 0,var(--bg) 42rem) }
    main { width:min(1180px,calc(100% - 32px)); margin:auto; padding:36px 0 54px } header { display:flex; justify-content:space-between; gap:20px; align-items:end; margin-bottom:26px }
    .eyebrow { color:var(--accent); font-size:.75rem; font-weight:750; letter-spacing:.16em; text-transform:uppercase } h1 { margin:6px 0 0; font-size:clamp(2rem,5vw,3.4rem); letter-spacing:-.05em; line-height:1 }
    .subtitle,.hint,.meta,footer { color:var(--muted) } .subtitle { margin:12px 0 0; max-width:650px } .meta { font-size:.82rem; text-align:right }
    .summary { display:grid; grid-template-columns:repeat(4,1fr); gap:12px; margin-bottom:26px } .metric,.notice,.details,.target-card,.jobs { border:1px solid var(--line); background:var(--panel); box-shadow:0 18px 50px #00000029 }
    .metric { border-radius:16px; padding:18px } .metric strong { display:block; font-size:1.8rem; letter-spacing:-.04em } .metric span { color:var(--muted); font-size:.82rem }
    .notice { border-radius:14px; padding:15px 18px; color:var(--warn); margin-bottom:18px } .notice.error { color:var(--bad) }
    .section-title { display:flex; justify-content:space-between; align-items:baseline; margin:0 0 12px } h2 { font-size:1rem; margin:0 }
    .targets { display:grid; grid-template-columns:repeat(auto-fit,minmax(270px,1fr)); gap:14px } .target-card { border-radius:18px; padding:18px; transition:transform .16s,border-color .16s,background .16s }
    .target-card:hover,.target-card:focus-within { transform:translateY(-2px); border-color:var(--accent); background:var(--strong) } .target-top { display:flex; justify-content:space-between; gap:12px; align-items:start }
    .target-name { font-size:1.05rem; font-weight:720; overflow-wrap:anywhere } .target-id { color:var(--muted); font:.76rem ui-monospace,monospace; margin-top:4px; overflow-wrap:anywhere }
    .pill { border-radius:999px; padding:5px 9px; font-size:.7rem; font-weight:750; white-space:nowrap } .pill.good { color:var(--good); background:#55d39a1f } .pill.warn { color:var(--warn); background:#f7c66b1f } .pill.security-warn { color:var(--security); background:#d783222b; border-color:#d7832266 } .pill.bad { color:var(--bad); background:#ff7e8b1f } .pill.neutral { color:var(--muted); background:#aab7cf1f }
    .target-info,.detail-grid { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:20px } .target-info span,.detail-grid span { display:block; color:var(--muted); font-size:.72rem; margin-bottom:4px } strong { overflow-wrap:anywhere }
    .actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:18px } button { border:1px solid var(--line); border-radius:9px; padding:9px 12px; color:var(--text); background:#ffffff0d; cursor:pointer; font:inherit; font-size:.82rem } button:hover:not(:disabled),button:focus-visible { border-color:var(--accent); outline:2px solid #73a7ff55 } button.primary { background:#73a7ff24; border-color:#73a7ff88 } button:disabled { cursor:not-allowed; opacity:.45 }
    .details,.jobs { border-radius:16px; padding:20px; margin-top:18px } .details h3 { margin:0 0 15px } .details-heading { display:flex; align-items:center; gap:12px; justify-content:space-between } .details-heading h3 { margin:0 } .details-close { padding:7px 10px; font-size:.72rem; color:var(--muted) } .detail-sections { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:16px } .detail-sections section { min-width:0; padding-top:12px; border-top:1px solid #94a3b815 } .detail-sections h4 { margin:0; font-size:.78rem; color:var(--accent) } .detail-sections .detail-grid { grid-template-columns:1fr; gap:10px; margin-top:10px } .error-text { color:var(--bad); white-space:pre-wrap; overflow-wrap:anywhere }
    .job { display:grid; grid-template-columns:1.6fr 1fr .9fr auto auto; gap:10px; align-items:center; padding:11px 0; border-bottom:1px solid var(--line); font-size:.82rem } .job:last-child { border-bottom:0 } .job code { overflow-wrap:anywhere } .job small,.job-meta { color:var(--muted) } .job-meta { grid-column:1 / -1; font-size:.7rem } .job-download { display:inline-flex; align-items:center; border:1px solid var(--line); border-radius:9px; padding:5px 9px; color:var(--muted); background:#ffffff0d; font-size:.7rem; text-decoration:none; white-space:nowrap } .job-download:hover,.job-download:focus-visible { border-color:var(--accent); color:var(--text); outline:2px solid #73a7ff55 } .log { max-height:220px; overflow:auto; white-space:pre-wrap; background:#00000045; border-radius:8px; padding:12px; margin-top:12px; color:#cbd5e1; font: .75rem ui-monospace,monospace } .log-actions { display:flex; justify-content:flex-end; align-items:center; gap:8px; margin:10px 0 0; flex-wrap:wrap } .log-actions + .log { margin-top:8px } .log-latest { padding:5px 9px; font-size:.7rem }
    .empty { border:1px dashed var(--line); border-radius:16px; padding:30px; text-align:center; color:var(--muted) } .node-scope-help { margin:8px 0 0; color:var(--muted); font-size:.74rem } footer { font-size:.75rem; margin-top:28px }
    @media (max-width:720px) { main { width:calc(100% - 22px); padding-top:25px } header { display:block } .meta { text-align:left; margin-top:15px } .summary { grid-template-columns:repeat(2,1fr) } .job { grid-template-columns:1fr 1fr } .job > button { grid-column:span 2; width:100%; text-align:center } }
    .app-main { width:min(1600px,100%); margin:0 auto; padding:34px clamp(18px,4vw,52px) 54px } .app-header { display:flex; justify-content:space-between; gap:20px; align-items:end; margin-bottom:26px } .systems-panel { padding:22px; border:1px solid var(--line); border-radius:18px; background:#151d34aa; box-shadow:0 18px 50px #00000029 } .view-note { color:var(--muted); font-size:.75rem } .node-group,.external-group { margin-top:18px; border:1px solid var(--line); border-radius:14px; overflow:hidden; background:#0e162b99 } .node-group:not(.open) { min-height:98px } .group-header { display:flex; align-items:center; justify-content:space-between; gap:12px; min-height:96px; padding:15px 16px; cursor:pointer } .group-header:hover { background:#73a7ff0d } .group-toggle { display:grid; place-items:center; flex:0 0 auto; width:38px; height:38px; padding:0; border:1px solid var(--line); border-radius:10px; color:var(--accent); background:#73a7ff0d } .group-toggle:hover { background:#73a7ff22 } .group-title { display:flex; align-items:center; gap:10px; flex:1; min-width:0 } .group-title strong { display:block; font-size:1rem; overflow-wrap:anywhere } .group-title small { display:block; color:var(--muted); font-size:.72rem; margin-top:4px } .group-summary { display:flex; align-items:center; gap:12px; color:var(--muted); font-size:.75rem; white-space:nowrap } .chevron { display:block; color:var(--accent); font-size:1.35rem; line-height:1; transition:transform .16s ease } .node-group.open .chevron,.external-group.open .chevron { transform:rotate(90deg) } .group-body { display:none; padding:0 12px 12px } .node-group.open .group-body,.external-group.open .group-body { display:block } .guest-list { display:grid; gap:6px } .target-row { display:grid; grid-template-columns:minmax(150px,1.5fr) .7fr .65fr .65fr .7fr .9fr auto; align-items:center; gap:10px; padding:10px 12px; border-top:1px solid #94a3b815; font-size:.78rem } .target-row:hover { background:#73a7ff0b } .target-row .target-name { font-size:.82rem } .target-row .target-id { margin-top:2px } .row-muted { color:var(--muted); font-size:.72rem } .row-actions { display:flex; justify-content:flex-end; gap:6px } .row-actions button { padding:7px 9px; font-size:.72rem } .target-card { min-height:205px; display:flex; flex-direction:column } .target-card .actions { margin-top:auto } .target-card .target-info { margin-top:15px } .external-group { grid-column:1 / -1; margin-top:20px } .external-group .group-body { padding-top:2px } .job-toggle { display:flex; align-items:center; gap:10px; border:0; padding:0; background:transparent; color:var(--text); font-weight:700; font-size:1rem } .job-count { color:var(--muted); font-size:.74rem; font-weight:500 } .jobs.collapsed .job-list { display:none } .job-list { margin-top:12px } .job-summary { color:var(--muted); font-size:.75rem } .detail-grid { grid-template-columns:repeat(3,1fr) }
    @media (max-width:900px) { .target-row { grid-template-columns:minmax(140px,1.4fr) .8fr .8fr auto; } .target-row .row-os { display:none } }
    @media (max-width:620px) { .app-main { padding:24px 11px 38px } .app-header { display:block } .meta { text-align:left; margin-top:13px } .systems-panel { padding:13px } .section-title { align-items:flex-start } .view-note { display:none } .group-summary { gap:6px; font-size:.68rem } .target-row { grid-template-columns:1fr auto; gap:5px 8px; padding:11px 8px } .target-row > :nth-child(2),.target-row > :nth-child(3),.target-row > :nth-child(4) { display:none } .row-actions { grid-column:2; grid-row:1 / span 2 } .row-actions button { min-height:38px } .detail-grid { grid-template-columns:1fr 1fr } }
    .brand-lockup { display:flex; align-items:flex-start; gap:16px; min-width:0 } .brand-logo { display:none } .brand-header-art { display:block; width:min(300px,70vw); height:auto; flex:0 0 auto; filter:drop-shadow(0 6px 14px #0005) } .brand-copy { min-width:0; padding-top:7px } .management-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:18px; margin-top:18px } .management-panel { border:1px solid var(--line); border-radius:16px; padding:20px; background:var(--panel); box-shadow:0 18px 50px #00000029 } .management-panel h2 { margin:0 } .management-panel .section-title { margin-bottom:16px } .management-form { display:none; gap:14px; grid-template-columns:1fr; margin-top:14px } .management-form.open { display:grid } .management-form label { color:var(--muted); font-size:.75rem } .management-form input,.management-form select { display:block; width:100%; margin-top:5px; border:1px solid var(--line); border-radius:8px; padding:9px 10px; color:var(--text); background:#0b1224; font:inherit } .management-form .form-wide { grid-column:1/-1 } .management-form .form-actions { display:flex; gap:8px; grid-column:1/-1 } .managed-target { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:10px 0; border-top:1px solid #94a3b815; font-size:.8rem } .managed-target:first-child { border-top:0 } .managed-target small { color:var(--muted); display:block; margin-top:3px } .managed-actions { display:flex; flex-wrap:wrap; gap:6px; justify-content:flex-end } .managed-actions button { padding:7px 9px; font-size:.72rem } .settings-group { border-top:1px solid var(--line); padding-top:15px; margin-top:15px } .settings-group:first-child { border-top:0; padding-top:0; margin-top:0 } .settings-group h3 { margin:0; font-size:.88rem } .settings-group p { color:var(--muted); font-size:.72rem; margin:5px 0 11px } .config-fields { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px 18px } .config-field { display:grid; grid-template-columns:auto 1fr; align-items:center; gap:8px; min-width:0; color:var(--muted); font-size:.78rem } .config-field input[type=checkbox] { grid-column:1; accent-color:var(--accent); width:17px; height:17px } .config-field input[type=text],.config-field input[type=number] { grid-column:2; min-width:0; border:1px solid var(--line); border-radius:8px; padding:8px; color:var(--text); background:#0b1224; font:inherit } .config-field input[type=text] { width:100% } .config-field .field-label { grid-column:1 / -1; grid-row:1; padding-left:25px } .config-field input[type=checkbox] + .field-label { grid-column:2; padding-left:0 } .config-field .field-unit { grid-column:2; color:var(--muted); font-size:.7rem; margin-top:-5px } .config-actions { display:flex; gap:8px; margin-top:18px; padding-top:14px; border-top:1px solid var(--line) } .management-message { color:var(--muted); font-size:.76rem; min-height:1.2em; margin-top:10px } .management-message.error { color:var(--bad) } .modal-backdrop { position:fixed; inset:0; z-index:5; display:none; place-items:center; padding:18px; background:#030712aa } .modal-backdrop.open { display:grid } .modal { width:min(520px,100%); border:1px solid var(--line); border-radius:16px; padding:20px; background:#151d34; box-shadow:0 24px 80px #0008 } .modal h3 { margin:0 0 15px } .modal .form-actions { display:flex; gap:8px; margin-top:14px } .modal-close { margin-left:auto } .login-branding { display:block; width:min(250px,100%); height:auto; margin:0 auto 16px; filter:drop-shadow(0 6px 14px #0005) } .login-account-hint { color:var(--muted); font-size:.76rem; margin:9px 0 0 }
    @media (max-width:760px) { .management-grid { grid-template-columns:1fr } .config-fields,.management-form { grid-template-columns:1fr } .management-form .form-wide { grid-column:auto } .management-form .form-actions { grid-column:auto } .managed-target { align-items:flex-start; flex-direction:column } .managed-actions { justify-content:flex-start } .login-branding { width:min(220px,100%) } }
    .auth-loading { text-align:center; color:var(--muted) } .auth-loading .login-branding { margin-bottom:8px } .management-message.success { color:var(--good) } .login-progress { display:flex; align-items:center; justify-content:center; gap:8px; min-height:1.2em; margin-top:10px; color:var(--muted); font-size:.76rem; visibility:hidden } .login-form.is-loading .login-progress { visibility:visible } .login-spinner { width:13px; height:13px; border:2px solid #91a0bd55; border-top-color:var(--accent); border-radius:50%; animation:login-spin .8s linear infinite } @keyframes login-spin { to { transform:rotate(360deg) } } .login-form.is-loading input { cursor:wait }
    .modal label { display:block; margin-top:12px; color:var(--muted); font-size:.78rem } .modal label input { display:block; width:100%; margin-top:5px; border:1px solid var(--line); border-radius:8px; padding:9px 10px; color:var(--text); background:#0b1224; font:inherit }
    .config-fields { grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px 18px } .config-field { grid-template-columns:minmax(0,1fr) auto; gap:7px 8px } .config-field input[type=checkbox] { grid-column:1; grid-row:1; justify-self:start } .config-field input[type=text],.config-field input[type=number] { grid-column:1 / -1; grid-row:2; width:100% } .config-field .field-label { grid-column:1 / -1; grid-row:1; min-width:0; padding-left:0 } .config-field input[type=checkbox] + .field-label { grid-column:2; justify-self:start } .config-field .field-unit { grid-column:1 / -1; grid-row:3; margin-top:-3px } .settings-group .settings-subtitle { color:var(--muted); font-size:.7rem; margin:13px 0 7px; letter-spacing:.04em; text-transform:uppercase }
    .node-grid { display:grid; grid-column:1/-1; width:100%; min-width:0; grid-template-columns:repeat(3,minmax(0,1fr)); gap:14px; justify-content:stretch } .node-grid > .node-group { width:100%; min-width:0 } .node-group { margin-top:0; min-height:0 !important } .node-group .group-header,.external-group .group-header { display:grid; grid-template-columns:42px minmax(0,1fr) auto; min-height:98px } .node-group .group-title small,.external-group .group-title small { white-space:nowrap } .node-group .group-summary { display:grid; grid-template-columns:auto auto; grid-template-rows:auto auto; gap:4px 8px; align-items:center } .node-group .group-summary .node-details { grid-column:1/-1; justify-self:end } .guest-panel { grid-column:1/-1; width:100%; min-width:0; margin-top:0; border:1px solid var(--line); border-radius:14px; overflow:hidden; background:#0e162b99 } .guest-panel-title { padding:13px 16px; color:var(--text); font-size:.78rem; font-weight:750; border-bottom:1px solid var(--line); background:#151d34aa } .guest-panel .guest-list { padding:0 12px 12px }
    @media (max-width:1180px) { .node-grid { grid-template-columns:repeat(2,minmax(280px,1fr)) } }
    .node-group .group-toggle,.external-group .group-toggle { border-color:transparent; background:transparent; border-radius:50%; width:32px; height:32px; color:var(--muted); transform:scale(1); outline:none; user-select:none; caret-color:transparent; -webkit-tap-highlight-color:transparent; transition:transform .17s cubic-bezier(.2,.8,.2,1),background-color .17s ease,color .17s ease,box-shadow .17s ease } .node-group .group-toggle:hover,.external-group .group-toggle:hover { background:#73a7ff18; color:var(--text); transform:scale(1.04); box-shadow:0 0 0 4px #73a7ff0d,0 4px 12px #0003 } .node-group .group-toggle:focus-visible,.external-group .group-toggle:focus-visible { outline:2px solid #8bb9ff; outline-offset:3px; box-shadow:0 0 0 4px #73a7ff22 } .chevron { width:10px; height:10px; border-right:2px solid currentColor; border-bottom:2px solid currentColor; transform:rotate(-45deg); transition:transform .17s cubic-bezier(.2,.8,.2,1),color .17s ease } .node-group.open .chevron,.external-group.open .chevron { transform:rotate(45deg); color:var(--accent) } .node-group .group-summary .node-details { background:transparent; color:var(--muted); padding:7px 10px; font-size:.72rem } .node-group .group-summary .node-action { padding:7px 9px; font-size:.7rem } .node-group .group-summary .node-update { background:#73a7ff1c; border-color:#73a7ff66 }
    .target-row { grid-template-columns:minmax(200px,1.4fr) .8fr .75fr .75fr minmax(180px,1.1fr) auto; min-width:720px } .guest-panel .guest-list { overflow-x:auto } .target-row > div { min-width:0 } .target-row .row-os strong,.target-row .row-muted { overflow-wrap:anywhere }
    .target-field { display:flex; flex-direction:column; gap:3px; min-width:0 } .target-label { color:var(--muted); font-size:.68rem; line-height:1.15; font-weight:650 } .target-field strong { font-size:.78rem; font-weight:400 } .target-status { justify-content:center } .target-status .pill { align-self:flex-start } .reboot-required { color:var(--warn) } .reboot-required-badge { display:inline-flex; align-items:center; border:1px solid #f7c66b66; border-radius:999px; padding:3px 7px; color:var(--warn); background:#f7c66b14; font-size:.68rem; font-weight:700; white-space:nowrap } .row-last-check strong { white-space:normal } .management-grid.config-open { grid-template-columns:1fr } #managed-targets > .empty { padding:18px; border-radius:10px; font-size:.78rem }
    .node-group .group-title strong { white-space:nowrap; overflow-wrap:normal }
    @media (max-width:620px) { .brand-lockup { gap:11px } .brand-header-art { width:min(260px,82vw) } .brand-copy { padding-top:0 } .subtitle { margin-top:9px; font-size:.82rem } .node-grid { grid-template-columns:1fr } .node-group .group-header { display:grid; grid-template-columns:42px minmax(0,1fr); gap:8px 10px; min-height:98px } .node-group .group-toggle { grid-column:1; grid-row:1 / span 2 } .node-group .group-title { grid-column:2; grid-row:1 } .node-group .group-summary { grid-column:2; grid-row:2; width:100%; justify-content:space-between; white-space:normal } .node-group .group-summary .node-details { margin-left:auto } .guest-panel { margin-top:0 } .guest-panel .guest-list { padding:0 8px 8px } .target-row { min-width:0; grid-template-columns:1fr auto; } .target-row .target-status { grid-column:1/-1; display:block } .target-row .target-field { display:grid; grid-template-columns:minmax(80px,.65fr) minmax(0,1.35fr); align-items:baseline; gap:8px; } .target-row .target-field .target-label { margin:0 } .target-row .row-os,.target-row .row-last-check { grid-column:1/-1; display:grid; grid-template-columns:minmax(80px,.65fr) minmax(0,1.35fr); align-items:baseline; gap:8px; } .target-row .row-actions { grid-column:1/-1; justify-content:flex-start; } .detail-sections { grid-template-columns:1fr; gap:12px } .details { padding:14px } }
    .settings-group { padding-top:10px; margin-top:10px } .settings-group h3 { font-size:.82rem } .settings-group p { margin:3px 0 7px; font-size:.68rem } .config-fields { gap:4px 16px } .settings-columns { display:grid; grid-template-columns:minmax(0,1fr) minmax(0,1fr); gap:18px; align-items:start } .settings-column { display:grid; gap:4px; align-content:start } .config-field.boolean-field { display:flex; align-items:center; gap:8px; min-height:28px; padding:2px 0; border:0; border-radius:0; background:transparent } .config-field.boolean-field input[type=checkbox] { flex:0 0 auto; width:16px; height:16px; margin:0; accent-color:var(--accent) } .config-field.boolean-field .field-label { padding:0; min-width:0; cursor:pointer } .config-field:not(.boolean-field):not(.numeric-field) { display:grid; grid-template-columns:minmax(120px,.8fr) minmax(0,1.2fr); align-items:center; gap:5px 10px } .config-field:not(.boolean-field):not(.numeric-field) .field-label { grid-column:1; grid-row:1; padding:0 } .config-field:not(.boolean-field):not(.numeric-field) input[type=text],.config-field:not(.boolean-field):not(.numeric-field) input[type=number] { grid-column:2; grid-row:1; min-width:0; width:100%; padding:6px 8px } .config-field:not(.boolean-field):not(.numeric-field) .field-unit { grid-column:2; grid-row:2; margin:-3px 0 0; font-size:.66rem } .config-field:not(.boolean-field).numeric-field { display:grid; grid-template-columns:minmax(120px,.8fr) auto auto; align-items:center; gap:5px 8px } .config-field:not(.boolean-field).numeric-field .field-label { grid-column:1; grid-row:1; padding:0 } .config-field:not(.boolean-field).numeric-field input[type=number] { grid-column:2; grid-row:1; width:76px; min-width:0; padding:6px 8px } .config-field:not(.boolean-field).numeric-field .field-unit { grid-column:3; grid-row:1; margin:0; white-space:nowrap; font-size:.66rem } .settings-group .settings-subtitle { display:none } .config-actions { position:sticky; bottom:0; z-index:1; margin-top:13px; padding:10px 0 2px; background:linear-gradient(var(--panel),var(--panel)); }
    @media (max-width:760px) { .config-fields,.settings-columns { grid-template-columns:1fr } .config-field:not(.boolean-field):not(.numeric-field) { grid-template-columns:minmax(105px,.75fr) minmax(0,1.25fr) } .config-field:not(.boolean-field).numeric-field { grid-template-columns:minmax(105px,.75fr) auto auto } .config-actions { position:static } }
    .filter-preview { margin-top:12px; padding:12px 14px; border:1px solid #73a7ff45; border-radius:12px; background:#73a7ff0b } .filter-preview-toggle { display:flex; align-items:center; gap:9px; width:100%; padding:0; border:0; background:transparent; color:var(--text); font-size:.84rem; font-weight:700; text-align:left; user-select:none; caret-color:transparent; outline:none } .filter-preview-toggle:hover { color:var(--accent) } .filter-preview-toggle:focus-visible { outline:2px solid #8bb9ff; outline-offset:3px } .filter-preview-chevron { display:grid; place-items:center; flex:0 0 28px; width:28px; height:28px; border-radius:8px; color:var(--muted); background:transparent; transform:scale(1); transition:transform .17s cubic-bezier(.2,.8,.2,1),background-color .17s ease,color .17s ease,box-shadow .17s ease } .filter-preview-chevron::after { content:""; width:8px; height:8px; border-right:2px solid currentColor; border-bottom:2px solid currentColor; transform:rotate(-45deg); transition:transform .17s cubic-bezier(.2,.8,.2,1) } .filter-preview-toggle:hover .filter-preview-chevron { color:var(--text); background:#73a7ff18; transform:scale(1.04); box-shadow:0 0 0 4px #73a7ff0d } .filter-preview.open .filter-preview-chevron { color:var(--accent) } .filter-preview.open .filter-preview-chevron::after { transform:rotate(45deg) } .filter-preview-details { display:none; grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px 24px; padding:12px 0 2px; border-top:1px solid #94a3b815; margin-top:10px } .filter-preview.open .filter-preview-details { display:grid } .filter-preview-details h4 { margin:0 0 5px; color:var(--muted); font-size:.68rem; font-weight:700; text-transform:uppercase; letter-spacing:.04em } .filter-preview-list { display:grid; gap:4px; color:var(--text); font-size:.75rem } .filter-preview-list div { overflow-wrap:anywhere } .filter-preview-list .excluded { color:var(--muted) } .filter-preview-list .unknown { color:var(--warn) } .filter-preview-note { color:var(--muted); font-size:.68rem; margin-top:6px }
    .config-actions { position:static; background:transparent; } .section-title h2 .help-control { margin-left:6px; vertical-align:middle; } .config-field .field-label { display:inline-flex; align-items:center; gap:6px; }
    .heading-with-help { display:inline-flex; align-items:center; gap:8px; min-width:0 } .help-control { position:relative; display:inline-flex; flex:0 0 auto } .help-trigger { display:grid; place-items:center; width:22px; height:22px; padding:0; border:1px solid #73a7ff66; border-radius:50%; color:var(--accent); background:#73a7ff0b; font:700 .72rem/1 inherit; user-select:none; caret-color:transparent; outline:none; cursor:help; transition:background-color .16s ease,color .16s ease,box-shadow .16s ease,transform .16s ease } .help-trigger:hover,.help-control.open .help-trigger { color:var(--text); background:#73a7ff22; box-shadow:0 0 0 4px #73a7ff0d; transform:scale(1.04) } .help-trigger:focus-visible { outline:2px solid #8bb9ff; outline-offset:3px } .help-popover { position:absolute; z-index:4; top:calc(100% + 8px); left:0; display:none; width:min(360px,calc(100vw - 42px)); padding:12px 14px; border:1px solid var(--line); border-radius:11px; color:var(--text); background:#151d34; box-shadow:0 16px 40px #0007; font-size:.74rem; font-weight:400; line-height:1.45; text-align:left } .help-control:hover .help-popover,.help-control.open .help-popover { display:block } .help-popover p { margin:0 } .help-popover p + p { margin-top:8px } .help-control.open .help-popover { animation:help-popover-in .14s ease-out } @keyframes help-popover-in { from { opacity:0; transform:translateY(-3px) } to { opacity:1; transform:translateY(0) } } .settings-heading { display:flex; align-items:center; gap:8px } .settings-heading h3 { margin:0 } .config-field select { grid-column:2; min-width:0; width:100%; border:1px solid var(--line); border-radius:8px; padding:6px 8px; color:var(--text); background:#0b1224; font:inherit }
    .filter-scopes { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:14px 18px } .filter-scope { min-width:0; padding:10px 12px; border:1px solid #94a3b81f; border-radius:10px; background:#0b122433 } .filter-scope h4 { margin:0 0 8px; color:var(--accent); font-size:.72rem; letter-spacing:.04em; text-transform:uppercase } .filter-scope .config-fields { grid-template-columns:1fr; gap:8px } .filter-scope .config-field:not(.boolean-field) { grid-template-columns:minmax(105px,.75fr) minmax(0,1.25fr) } .filter-scope .filter-preview { margin-top:10px }
    .check-update-matrix { display:grid; grid-template-columns:minmax(0,1fr) 58px 58px; border:1px solid #94a3b81f; border-radius:10px; overflow:hidden; background:#0b122433 } .matrix-row { display:contents } .matrix-label,.matrix-cell { min-width:0; padding:7px 8px; border-bottom:1px solid #94a3b815 } .matrix-label { color:var(--text); font-size:.76rem; overflow-wrap:anywhere } .matrix-cell { display:grid; place-items:center; justify-items:center } .matrix-head { color:var(--muted); font-size:.68rem; font-weight:700; text-align:center; justify-items:center } .matrix-row:last-child > * { border-bottom:0 } .matrix-control { width:fit-content; margin:0; justify-self:center; color:var(--muted) } .matrix-control .field-label { position:absolute; width:1px; height:1px; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap } .matrix-control input[type=checkbox] { margin:0 } .matrix-empty { justify-self:center; color:var(--muted); font-size:.8rem } .matrix-extras { display:grid; grid-template-columns:minmax(0,1fr) auto; align-items:center; gap:8px 24px; margin-top:10px } .matrix-extra-row { display:flex; justify-self:start; align-items:center; gap:8px; min-width:0; color:var(--muted); font-size:.78rem } .delay-label { flex:0 0 auto; white-space:nowrap } .delay-control { display:inline-flex; flex:0 0 auto; align-items:center; gap:5px } .delay-control input[type=number] { width:76px; min-width:0; padding:6px 8px; border:1px solid var(--line); border-radius:8px; color:var(--text); background:#0b1224; font:inherit } .delay-control .field-unit { white-space:nowrap; color:var(--muted); font-size:.7rem } .matrix-extras > .boolean-field { width:fit-content; justify-self:end; max-width:100% }
    @media (max-width:760px) { .check-update-matrix { grid-template-columns:minmax(0,1fr) 54px 54px } .matrix-extras { grid-template-columns:1fr; gap:6px } .matrix-extras > .boolean-field { justify-self:start } .matrix-extra-row { flex-wrap:wrap } }
    .node-group .group-header { display:grid; grid-template-columns:32px minmax(0,1fr); grid-template-rows:auto auto; align-items:center; gap:7px 10px; min-height:0 } .node-group .group-toggle { grid-column:1; grid-row:1 / span 2 } .node-group .group-title { grid-column:2; grid-row:1; min-width:0; align-self:end } .node-group .group-title strong { white-space:normal; overflow-wrap:anywhere } .node-group .group-title small { white-space:normal; overflow-wrap:anywhere } .node-group .group-summary { grid-column:2; grid-row:2; display:flex; flex-wrap:wrap; justify-content:flex-start; gap:6px; min-width:0; white-space:normal } .node-group .group-summary .node-details { margin-left:0; justify-self:auto } .node-group .group-summary .node-action { min-width:0 } .config-field.boolean-field { width:fit-content; max-width:100%; justify-self:start; cursor:pointer } .config-field.boolean-field:hover { color:var(--text) } .check-update-matrix .config-field.boolean-field { justify-self:center } .matrix-extras > .config-field.boolean-field { justify-self:end }
    @media (max-width:760px) { .matrix-extras > .config-field.boolean-field { justify-self:start } }
    .node-group .group-header { grid-template-columns:32px minmax(0,1fr) auto; grid-template-rows:auto auto auto; gap:5px 10px; padding:13px 14px } .node-group .group-toggle { grid-column:1; grid-row:1 / span 3 } .node-group .group-title { grid-column:2; grid-row:1 / span 2; align-self:center } .node-group .group-status { grid-column:3; grid-row:1; justify-self:end } .node-group .group-updates { grid-column:3; grid-row:2; justify-self:end; color:var(--muted); font-size:.72rem; white-space:nowrap } .node-group .group-actions { grid-column:2 / -1; grid-row:3; display:flex; flex-wrap:wrap; justify-content:flex-start; gap:6px; min-width:0; padding-top:3px } .node-group .group-actions button { min-width:0; padding:6px 8px; font-size:.69rem } .node-group .group-actions .node-update { background:#73a7ff1c; border-color:#73a7ff66 } .node-group .group-title strong { overflow-wrap:anywhere } .node-group .group-title small { display:block; margin-top:4px; line-height:1.25 }
    @media (max-width:1250px) and (min-width:621px) { .node-grid { grid-template-columns:repeat(2,minmax(280px,1fr)) } }
    @media (max-width:620px) { .node-group .group-header { grid-template-columns:32px minmax(0,1fr) auto; grid-template-rows:auto auto auto; min-height:0; } .node-group .group-toggle { grid-column:1; grid-row:1 / span 3 } .node-group .group-title { grid-column:2; grid-row:1 / span 2 } .node-group .group-status { grid-column:3; grid-row:1; } .node-group .group-updates { grid-column:3; grid-row:2; } .node-group .group-actions { grid-column:2 / -1; grid-row:3; } }
    .node-group { display:flex; flex-direction:column; min-height:0 } .node-group .group-header { display:grid; grid-template-columns:32px minmax(0,1fr) auto; align-items:start; gap:8px 10px; min-height:0; padding:13px 14px 8px } .node-group .group-toggle { grid-column:1; grid-row:1; } .node-group .group-title { grid-column:2; grid-row:1; min-width:0; align-self:start } .node-group .group-title strong { display:block; white-space:normal; overflow-wrap:anywhere; line-height:1.2 } .node-group .group-title small { display:block; margin-top:5px; white-space:normal; overflow-wrap:anywhere; line-height:1.25 } .node-group .group-status { display:flex; grid-column:3; grid-row:1; justify-self:end; align-items:center; justify-content:flex-end; flex-wrap:wrap; gap:6px; min-width:0; max-width:100% } .node-group .group-status .pill,.node-group .group-status .reboot-required-badge { flex:0 0 auto } .node-group .group-info { display:flex; align-items:center; min-width:0; padding:0 14px 10px 56px; color:var(--muted); font-size:.74rem; line-height:1.25 } .node-group .group-updates { white-space:normal; overflow-wrap:anywhere } .node-group .group-actions { display:flex; flex-wrap:wrap; align-items:center; justify-content:flex-start; gap:6px; min-width:0; padding:10px 14px 13px 56px; border-top:1px solid #94a3b815; margin-top:auto } .node-group .group-actions button { min-width:0; padding:6px 9px; font-size:.7rem; white-space:nowrap } .node-group .group-actions .node-update { background:#73a7ff1c; border-color:#73a7ff66 }
    @media (max-width:620px) { .node-group .group-header { grid-template-columns:32px minmax(0,1fr) auto; } .node-group .group-status { max-width:calc(100vw - 104px); } .node-group .group-info { padding-left:56px; } .node-group .group-actions { padding-left:56px; } }
    /* Keep the node identity on its own full row; only the status group wraps. */
    .node-group .group-header { grid-template-columns:32px minmax(0,1fr); grid-template-rows:auto auto; align-items:start; min-width:0; }
    .node-group .group-toggle { grid-column:1; grid-row:1 / span 2; }
    .node-group .group-title { grid-column:2; grid-row:1; min-width:0; align-self:start; }
    .node-group .group-title strong,.node-group .group-title small { white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .node-group .group-status { grid-column:2; grid-row:2; justify-self:start; justify-content:flex-start; width:100%; max-width:none; }
    @media (max-width:760px) { .filter-preview-details,.filter-scopes { grid-template-columns:1fr } }
    .internal-ssh-add { margin-top:9px; padding:6px 9px; font-size:.72rem; color:var(--muted) } .internal-ssh-add:hover { color:var(--text) } .internal-ssh-view { max-width:900px; margin:18px auto 0 } .internal-ssh-retry { margin-left:7px; padding:5px 8px; font-size:.72rem } .internal-ssh-target-picker[hidden],.internal-ssh-target-summary[hidden] { display:none !important } .internal-ssh-target-summary { display:grid; gap:4px; padding:8px 10px; border:1px solid var(--line); border-radius:8px; background:#0b122433 } .internal-ssh-target-summary strong { font-size:.7rem; color:var(--muted); font-weight:600 } .internal-ssh-target-picker select { width:100%; min-height:40px; margin-top:5px; padding:9px 10px; border:1px solid var(--line); border-radius:8px; color:var(--text); background:#0b1224; font:inherit } .ssh-enabled-field { display:flex; align-items:center; gap:8px; min-height:28px } .ssh-enabled-field input[type=checkbox] { flex:0 0 auto; width:16px; height:16px; margin:0; accent-color:var(--accent) } .ssh-state { display:block; margin-top:3px; color:var(--muted); font-size:.72rem } .ssh-state.disabled { opacity:.72 } .ssh-test-feedback { display:block; margin-top:5px; color:var(--muted); font-size:.72rem } .ssh-test-feedback.success { color:var(--good) } .ssh-test-feedback.error { color:var(--bad) }
    .app-header { display:grid; grid-template-columns:minmax(0,1fr) auto; column-gap:24px; align-items:start; margin-bottom:10px } .brand-header-art { width:min(260px,70vw) } .brand-copy { padding-top:0 } .subtitle { margin-top:5px } .app-header .meta { max-width:360px; padding-top:10px; align-self:start }
    @media (max-width:760px) { .app-header { display:block; margin-bottom:10px } .app-header .meta { max-width:none; padding-top:0 } }
    @media (max-width:620px) { .brand-header-art { width:min(250px,82vw) } .subtitle { margin-top:5px } .app-header .meta { margin-top:8px } }
    .dashboard-header { display:block; margin-bottom:18px; padding:20px 22px 18px; border:1px solid var(--line); border-radius:18px; background:#151d34aa; box-shadow:0 18px 50px #00000029 } .dashboard-header-top { display:grid; grid-template-columns:minmax(0,1fr) auto; align-items:start; gap:20px } .dashboard-brand { min-width:0 } .dashboard-brand .brand-lockup { gap:16px } .dashboard-brand .brand-header-art { width:min(370px,70vw) } .dashboard-brand .subtitle { margin:5px 0 0; max-width:650px } .dashboard-meta { align-self:start; max-width:360px; padding-top:10px; color:var(--muted); font-size:.82rem; text-align:right } .dashboard-meta button { margin-left:10px; padding:5px 8px; font-size:.7rem } .dashboard-kpis { margin:16px 0 0; }
    .dashboard-meta > button { box-sizing:border-box; display:inline-flex; align-items:center; justify-content:center; height:32px; min-height:32px; margin:0 0 0 10px; padding:0 9px; vertical-align:middle } .job-running-indicator { gap:7px; border-color:#55d39a55; color:var(--good); background:#55d39a12; font-size:.72rem; font-weight:750 } .job-running-indicator[hidden] { display:none } .job-running-dot { width:7px; height:7px; border-radius:50%; background:var(--good); box-shadow:0 0 0 3px #55d39a18; animation:job-pulse 1.8s ease-in-out infinite } @keyframes job-pulse { 0%,100% { opacity:.55; transform:scale(.92) } 50% { opacity:1; transform:scale(1.05) } } .updater-update-indicator { color:var(--warn); border-color:#f7c66b66; background:#f7c66b12; font-size:.72rem; font-weight:750; animation:updater-blink 2.2s ease-in-out infinite } .updater-update-indicator[hidden] { display:none } @keyframes updater-blink { 0%,100% { opacity:.62 } 50% { opacity:1 } } .version-footer { padding:0; border:0; background:transparent; color:inherit; font-size:inherit } .version-footer:hover { color:var(--text) } .version-components { width:100%; border-collapse:collapse; margin-top:12px; font-size:.78rem } .version-components th,.version-components td { padding:7px 5px; border-bottom:1px solid var(--line); text-align:left } .version-components th { color:var(--muted); font-weight:500 } @media (prefers-reduced-motion:reduce) { .job-running-dot,.updater-update-indicator { animation:none } }
    .global-actions { display:flex; flex-wrap:wrap; align-items:center; justify-content:space-between; gap:14px; margin:0 0 18px; padding:16px 18px; border:1px solid #73a7ff55; border-radius:16px; background:#19233f99; box-shadow:0 18px 50px #00000029 } .global-actions-copy { min-width:0 } .global-actions-copy strong { display:block; font-size:.92rem } .global-actions-copy span { display:block; margin-top:4px; color:var(--muted); font-size:.74rem } .global-actions-buttons { display:flex; flex-wrap:wrap; gap:9px } .global-action { min-height:42px; padding:10px 16px; font-weight:750; font-size:.84rem } .global-action.update-all { background:#73a7ff36; border-color:#73a7ffb8 } .global-action.check-all { background:#55d39a18; border-color:#55d39a77 }
    @media (max-width:760px) { .dashboard-header { padding:16px 14px 15px; margin-bottom:14px } .dashboard-header-top { display:block } .dashboard-brand .brand-header-art { width:min(270px,82vw) } .dashboard-meta { max-width:none; padding-top:0; margin-top:8px; text-align:left; font-size:.76rem } .dashboard-kpis { margin-top:14px } }
    @media (max-width:620px) { .global-actions { display:block; padding:14px } .global-actions-buttons { display:grid; grid-template-columns:1fr; margin-top:12px } .global-action { width:100% } }
    /* Keep guest status separate from the update metrics.  The row can stay
       compact on wide screens, but never compress the badge into the metric
       columns when the available width gets smaller. */
    .target-row { grid-template-columns:minmax(170px,1.35fr) minmax(190px,1.25fr) repeat(3,minmax(72px,.7fr)) minmax(150px,1fr) auto; }
    .target-row.split-row { grid-template-columns:minmax(180px,1.5fr) minmax(120px,.9fr) repeat(2,minmax(72px,.7fr)) minmax(80px,.75fr) minmax(140px,1.2fr) minmax(150px,1fr) minmax(132px,max-content); }
    .target-row.total-only-row { grid-template-columns:minmax(180px,1.5fr) minmax(120px,.9fr) minmax(80px,.75fr) minmax(80px,.75fr) minmax(140px,1.2fr) minmax(150px,1fr) minmax(132px,max-content); }
    .target-row .target-status { min-width:0; justify-content:flex-start; }
    .target-row .target-status .pill { max-width:100%; overflow-wrap:anywhere; text-align:left; }
    .target-row .target-field { min-width:0; }
    .target-row .row-os { min-width:130px; }
    .target-row .row-last-check { min-width:150px; }
    .target-row .row-actions { min-width:max-content; white-space:nowrap; }
    .target-row .target-field strong,.target-row .target-label { min-width:0; overflow-wrap:anywhere; }
    @media (max-width:1080px) and (min-width:761px) {
      .target-row { grid-template-columns:minmax(150px,1.25fr) minmax(175px,1.15fr) repeat(3,minmax(68px,.7fr)) minmax(130px,.9fr) auto; gap:8px; }
      .target-row.split-row { grid-template-columns:minmax(160px,1.35fr) minmax(110px,.85fr) repeat(2,minmax(68px,.7fr)) minmax(76px,.7fr) minmax(130px,1fr) minmax(145px,1fr) minmax(132px,max-content); }
      .target-row.total-only-row { grid-template-columns:minmax(160px,1.35fr) minmax(110px,.85fr) minmax(76px,.7fr) minmax(76px,.7fr) minmax(130px,1fr) minmax(145px,1fr) minmax(132px,max-content); }
    }
    @media (max-width:760px) {
      .target-row { grid-template-columns:repeat(3,minmax(0,1fr)); align-items:start; gap:8px; padding:12px 10px; }
      .target-row.split-row,.target-row.total-only-row { grid-template-columns:repeat(3,minmax(0,1fr)); }
      .target-row > :first-child,.target-row .target-status,.target-row .row-os,.target-row .row-last-check,.target-row .row-actions { grid-column:1 / -1; }
      .target-row .target-status { display:flex; }
      .target-row .target-field { display:flex; }
      .target-row .row-actions { justify-content:flex-start; }
      .target-row .row-actions button { min-height:38px; }
    }
    @media (max-width:430px) {
      .target-row { grid-template-columns:repeat(2,minmax(0,1fr)); }
      .target-row.split-row,.target-row.total-only-row { grid-template-columns:repeat(2,minmax(0,1fr)); }
    }
    .target-row.lxc-row { grid-template-columns:minmax(170px,1.35fr) minmax(190px,1.25fr) repeat(2,minmax(72px,.7fr)) minmax(150px,1fr) auto; }
    .target-row.lxc-row.split-row { grid-template-columns:minmax(180px,1.5fr) minmax(120px,.9fr) repeat(2,minmax(72px,.7fr)) minmax(140px,1.2fr) minmax(150px,1fr) minmax(132px,max-content); }
    @media (max-width:1080px) and (min-width:761px) {
      .target-row.lxc-row { grid-template-columns:minmax(150px,1.25fr) minmax(175px,1.15fr) repeat(2,minmax(68px,.7fr)) minmax(130px,.9fr) auto; }
      .target-row.lxc-row.split-row { grid-template-columns:minmax(160px,1.35fr) minmax(110px,.85fr) repeat(2,minmax(68px,.7fr)) minmax(130px,1fr) minmax(145px,1fr) minmax(132px,max-content); }
    }
    @media (max-width:760px) {
      .target-row.lxc-row { grid-template-columns:repeat(3,minmax(0,1fr)); }
      .target-row.lxc-row.split-row,.target-row.lxc-row.total-only-row { grid-template-columns:repeat(3,minmax(0,1fr)); }
    }
    @media (max-width:430px) {
      .target-row.lxc-row { grid-template-columns:repeat(2,minmax(0,1fr)); }
      .target-row.lxc-row.split-row,.target-row.lxc-row.total-only-row { grid-template-columns:repeat(2,minmax(0,1fr)); }
    }
    /* Job log actions share one compact button treatment. The download link
       is intentionally secondary, but must align with Show/Hide log. */
    .job > button[data-job], .job .job-download, .job .log-latest { display:inline-flex; align-items:center; justify-content:center; min-height:34px; padding:8px 11px; border:1px solid var(--line); border-radius:9px; font:inherit; font-size:.72rem; line-height:1.15; white-space:nowrap }
    .job > button[data-job] { min-width:92px }
    .job .job-download { color:var(--muted); background:#ffffff0d; text-decoration:none }
    .job .job-download:hover,.job .job-download:focus-visible { border-color:var(--accent); color:var(--text); outline:2px solid #73a7ff55 }
    .job .log-actions { grid-column:5; margin:0; justify-content:flex-start; min-width:0 }
    .job .log { grid-column:1 / -1; width:100%; min-width:0 }
    @media (max-width:720px) {
      .job { grid-template-columns:minmax(0,1fr) minmax(0,1fr); align-items:start }
      .job > code, .job > span:not(.pill), .job > .pill, .job > button[data-job] { min-width:0 }
      .job > code { grid-column:1 / -1 }
      .job > span:not(.pill) { grid-column:1 / -1 }
      .job > .pill { grid-column:1 }
      .job > button[data-job] { grid-column:2; grid-row:3; width:auto }
      .job .log-actions { grid-column:1 / -1; grid-row:4; justify-content:flex-start }
      .job .log { grid-column:1 / -1; grid-row:5 }
    }
  </style>
</head>
<body>
  <section id="auth-loading" class="modal-backdrop open" aria-live="polite"><div class="modal auth-loading"><img class="login-branding" src="/assets/ultimate-updater-header.png" alt="Ultimate Updater"><p>Loading…</p></div></section>
  <section id="login-screen" class="modal-backdrop" aria-label="Sign in"><form id="login-form" class="modal"><img class="login-branding" src="/assets/ultimate-updater-header.png" alt="Ultimate Updater"><h2>Ultimate Updater</h2><p class="hint">Sign in to access system status and actions.</p><p class="login-account-hint">Please use your current root account to sign in.</p><label>Username<input name="username" autocomplete="username" required></label><label>Password<input name="password" type="password" autocomplete="current-password" required></label><div class="form-actions"><button class="primary" type="submit">Sign in</button></div><div id="login-progress" class="login-progress" role="status" aria-live="polite"><span class="login-spinner" aria-hidden="true"></span><span>Signing in…</span></div><div id="login-message" class="management-message" role="alert"></div></form></section>
  <main class="app-main" id="dashboard" hidden>
    <header class="dashboard-header"><div class="dashboard-header-top"><div class="dashboard-brand"><div class="brand-lockup"><div class="brand-copy"><img class="brand-header-art" src="/assets/ultimate-updater-header.png" alt="Ultimate Updater"><h1 class="visually-hidden">Ultimate Updater</h1></div></div><p class="subtitle">A clear overview of updates across your systems.</p></div><div class="dashboard-meta"><span id="generated">Loading status…</span><button id="job-running-indicator" class="job-running-indicator" type="button" hidden aria-controls="jobs"><span class="job-running-dot" aria-hidden="true"></span><span id="job-running-label">Job running</span></button><button id="updater-version-indicator" class="updater-update-indicator" type="button" hidden>Updater update available</button><button id="logout" type="button">Log out</button></div></div><section class="summary dashboard-kpis"><div class="metric"><strong id="total">–</strong><span>known systems</span></div><div class="metric"><strong id="online">–</strong><span>reachable</span></div><div class="metric"><strong id="normal-updates">–</strong><span>normal updates</span></div><div class="metric"><strong id="security-updates">–</strong><span>security updates</span></div><div class="metric"><strong id="other-updates">–</strong><span>other updates</span></div><div class="metric"><strong id="attention">–</strong><span>needs attention</span></div></section></header>
    <div id="notice" hidden></div>
    <section class="global-actions" aria-labelledby="global-actions-title"><div class="global-actions-copy"><strong id="global-actions-title">Run the configured updater</strong><span>Configured include/exclude and safety rules are respected.</span></div><div class="global-actions-buttons"><button id="check-all" class="global-action check-all" type="button">Check all systems</button><button id="update-all" class="global-action update-all" type="button">Update all systems</button></div></section>
    <section id="systems" class="systems-panel"><div class="section-title"><div class="heading-with-help"><div><h2>Systems</h2><span class="hint">Organized by Proxmox node and external target</span></div><span class="help-control"><button class="help-trigger" type="button" aria-label="About Systems" aria-expanded="false" aria-controls="systems-help-popover">?</button><span id="systems-help-popover" class="help-popover" role="tooltip"><p>Systems shows the complete active inventory grouped by Proxmox node and external target. Status and update information comes from the latest available check data.</p><p>Guests without current update information remain part of the inventory; status data is only an enrichment of the inventory.</p></span></span></div><span class="view-note">Checks and updates use the existing CLI</span></div><p class="node-scope-help">Check/Update node: Only this node. LXCs and VMs are not checked or updated.</p><div id="targets" class="targets"></div><section id="details" class="details" hidden></section></section>
    <section class="management-grid">
      <section class="management-panel" id="config-panel"><div class="section-title"><div><h2>Configuration</h2><span class="hint">Known settings only · update.conf remains the source of truth</span></div><button id="config-open">Open settings</button></div><form id="config-form" class="management-form"></form><div id="config-message" class="management-message"></div></section>
      <section class="management-panel" id="internal-ssh-card"><div class="section-title"><div><h2>Internal SSH Connections <span class="help-control"><button class="help-trigger" type="button" aria-label="About Internal SSH Connections" aria-expanded="false" aria-controls="internal-ssh-help">?</button><span id="internal-ssh-help" class="help-popover" role="tooltip"><p>Cluster nodes are detected automatically. Add an SSH connection only when a VM or LXC requires direct SSH access.</p><p>External systems are managed separately under External Targets.</p></span></span></h2><span class="hint">Manage SSH access for nodes and internal guests.</span></div><button id="internal-ssh-open" type="button">Open SSH settings</button></div></section>
      <section class="management-panel" id="external-panel"><div class="section-title"><div><h2>External systems</h2><span class="hint">SSH targets from targets.conf</span></div><button id="target-add">+ Add system</button></div><div id="managed-targets"></div><form id="target-form" class="management-form"></form><div id="target-message" class="management-message"></div></section>
    </section>
    <section class="management-panel internal-ssh-view" id="internal-ssh-view" hidden><div class="section-title"><div><h2>Internal SSH Connections</h2><span class="hint">Nodes are detected automatically; add guest SSH access only when needed.</span></div><button id="internal-ssh-back" type="button">Back to overview</button></div><div class="settings-group"><h3>Proxmox Nodes</h3><div id="internal-ssh-nodes"><div class="empty">Loading…</div></div></div><div class="settings-group"><h3>Virtual Machines</h3><div id="internal-ssh-vms"><div class="empty">Loading…</div></div><button type="button" class="internal-ssh-add" data-ssh-add="vm">+ Add VM SSH connection</button></div><div class="settings-group"><h3>LXC Containers</h3><div id="internal-ssh-lxcs"><div class="empty">Loading…</div></div><button type="button" class="internal-ssh-add" data-ssh-add="lxc">+ Add LXC SSH connection</button></div><div id="internal-ssh-message" class="management-message"></div></section>
    <section id="jobs" class="jobs" hidden></section>
    <footer><button id="updater-version-footer" class="version-footer" type="button">Ultimate Updater <span id="updater-version-label">version unavailable</span></button></footer>
  </main>
  <div id="external-settings-modal" class="modal-backdrop" role="dialog" aria-modal="true"><form id="external-settings-form" class="modal"><div style="display:flex;align-items:center;gap:10px"><h3>External settings</h3><button type="button" class="modal-close" id="external-settings-close">Close</button></div><p class="hint">These settings are stored on this external system.</p><input type="hidden" name="target"><label>Only check filter<input name="ONLY_UPDATE_CHECK"></label><label>Exclude check filter<input name="EXCLUDE_UPDATE_CHECK"></label><label>Only update filter<input name="ONLY"></label><label>Exclude update filter<input name="EXCLUDE"></label><div class="form-actions"><button type="submit" class="primary">Save external settings</button></div><div id="external-settings-message" class="management-message" role="status"></div></form></div>
  <div id="internal-ssh-modal" class="modal-backdrop" role="dialog" aria-modal="true"><form id="internal-ssh-form" class="modal"><div style="display:flex;align-items:center;gap:10px"><h3 id="internal-ssh-title">Internal SSH settings</h3><button type="button" class="modal-close" id="internal-ssh-close">Close</button></div><p class="hint">Use custom SSH settings for this system. Without an override, Ultimate Updater uses the existing connection settings.</p><input type="hidden" name="kind"><input type="hidden" name="id"><label id="internal-ssh-target-picker">Select target<select name="target_choice"></select></label><div id="internal-ssh-target-summary" class="internal-ssh-target-summary" hidden><strong>Target</strong><span></span></div><label>Host / Address<input name="host" required></label><label>User<input name="user" value="root" required></label><label>Port<input name="port" type="number" min="1" max="65535" value="22" required></label><label>Identity file (optional)<input name="identity_file" placeholder="/root/.ssh/key"></label><label class="ssh-enabled-field"><input name="enabled" type="checkbox" checked><span>Use custom SSH settings</span></label><div class="form-actions"><button type="submit" class="primary" id="internal-ssh-save">Save SSH settings</button><button type="button" id="internal-ssh-remove">Remove override</button></div><div id="internal-ssh-form-message" class="management-message" role="status"></div></form></div>
  <div id="updater-version-modal" class="modal-backdrop" role="dialog" aria-modal="true" aria-labelledby="updater-version-title"><section class="modal"><div style="display:flex;align-items:center;gap:10px"><h3 id="updater-version-title">Ultimate Updater version</h3><button type="button" class="modal-close" id="updater-version-close">Close</button></div><div id="updater-version-content"><p class="hint">Loading version information…</p></div><div class="form-actions"><button type="button" id="updater-version-check">Check again</button><button type="button" class="primary" id="updater-version-update">Update now</button></div><div id="updater-version-message" class="management-message" role="status"></div></section></div>
  <script>
    const labels={ok:['Healthy','good'],updates_available:['Updates available','warn'],offline:['Offline','bad'],unsupported:['Unsupported','neutral'],not_checked:['Not checked','neutral'],error:['Error','bad']};
    const text=(v,f='Unknown')=>v===null||v===undefined||v===''?f:String(v); const esc=v=>text(v,'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const date=v=>{if(!v)return'Unknown';const d=new Date(v);return Number.isNaN(d.getTime())?String(v):d.toLocaleString()}; const statusLabel=v=>labels[v]||['Unknown','neutral']; const set=(id,v)=>document.getElementById(id).textContent=v;
    const LOG_BOTTOM_TOLERANCE=10;
    let currentStatus={targets:[]}, jobs=[], pollTimer, openJobLogId=null, logAutoFollow=true, logScrollTop=0, suppressLogScroll=false, finalLogLoaded=new Set(), logLoading=new Set(), csrfToken=null;
    function setLoginLoading(loading){const form=document.getElementById('login-form'),button=form.querySelector('button[type="submit"]');form.classList.toggle('is-loading',loading);form.dataset.submitting=loading?'true':'false';button.disabled=loading;button.textContent=loading?'Signing in…':'Sign in';form.querySelectorAll('input').forEach(input=>{input.disabled=loading})}
    function showLogin(message=''){setLoginLoading(false);document.getElementById('auth-loading').classList.remove('open');document.getElementById('dashboard').hidden=true;document.getElementById('login-screen').classList.add('open');const status=document.getElementById('login-message');status.className='management-message';status.textContent=message;csrfToken=null}
    function showDashboard(){document.getElementById('auth-loading').classList.remove('open');document.getElementById('login-screen').classList.remove('open');document.getElementById('dashboard').hidden=false}
    async function ensureSession(){const r=await fetch('/api/session',{cache:'no-store'});const d=await r.json();if(!r.ok){showLogin(d.error?.message||'Please sign in.');throw new Error(d.error?.message||'Authentication required.')}csrfToken=d.csrf;return d}
    async function api(path,options={}){if(!csrfToken)await ensureSession();const headers={'Content-Type':'application/json',...(options.headers||{})};if(csrfToken)headers['X-CSRF-Token']=csrfToken;const r=await fetch(path,{...options,headers});const d=await r.json();if(r.status===401){showLogin(d.error?.message||'Session expired.')}if(!r.ok){const error=new Error(d.error?.message||'Request failed');error.code=d.error?.code;throw error}return d}
    function notice(message,error=false){const n=document.getElementById('notice');n.hidden=false;n.textContent=message;n.className=error?'notice error':'notice'}
    function running(target){return jobs.some(j=>j.target===target&&j.state==='running')}
    function renderDetails(t){const rebootDetail=t.type==='lxc'?'':`<div><span>Reboot required</span><strong>${t.reboot_required===null?'Unknown':t.reboot_required?'Yes':'No'}</strong></div>`;const n=document.getElementById('details'),[label,tone]=statusLabel(t.check_status),e=t.error?`${text(t.error.code,'')}${t.error.message?': '+t.error.message:''}`:'None';n.hidden=false;n.innerHTML=`<h3>${esc(t.id)}</h3><div class="detail-grid"><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Transport</span><strong>${esc(t.transport)}</strong></div><div><span>Operating system</span><strong>${esc(t.os)}</strong></div><div><span>Updater</span><strong>${esc(t.updater)}</strong></div><div><span>Check status</span><strong class="pill ${tone}">${label}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div>${rebootDetail}<div><span>Last update</span><strong>${esc(t.last_update&&t.last_update.status)}</strong></div><div><span>Error</span><strong class="error-text">${esc(e)}</strong></div></div>`;n.scrollIntoView({behavior:'smooth',block:'nearest'})}
    async function action(path,update=false,options={}){if(update&&!options.confirmed&&!confirm(`Start update for "${path.split('/').pop()}"?`))return;try{const d=await api(path,{method:'POST',body:options.override?JSON.stringify({allow_without_backup:true}):'{}'});notice(d.message||'Action accepted.');await loadStatus();await loadJobs()}catch(e){if(update&&e.code==='EXTERNAL_BACKUP_REQUIRED'&&!options.override){if(confirm('No recent backup is verified for this external system.\n\nProceed without verified backup for this update only?'))return action(path,true,{confirmed:true,override:true})}else notice(e.message,true)}}
    function render(data){currentStatus=data;const ts=Array.isArray(data.targets)?data.targets:[];set('total',ts.length);set('online',ts.filter(t=>t.reachable===true).length);set('attention',ts.filter(t=>t.check_status!=='ok').length);set('generated',`Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);const list=document.getElementById('targets');list.replaceChildren();if(!ts.length){list.innerHTML='<div class="empty">No target status is available yet. Run a check to populate the view.</div>';return}for(const t of ts){const [label,tone]=statusLabel(t.check_status),u=t.updates&&Number.isInteger(t.updates.available)?t.updates.available:'Unknown';const card=document.createElement('article');card.className='target-card';card.innerHTML=`<div class="target-top"><div><div class="target-name">${esc(t.id)}</div><div class="target-id">${esc(t.os)} · ${esc(t.transport)}</div></div><span class="pill ${tone}">${label}</span></div><div class="target-info"><div><span>Updates</span><strong>${u}</strong></div><div><span>Reachability</span><strong>${t.reachable===true?'Online':t.reachable===false?'Offline':'Unknown'}</strong></div><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div></div><div class="actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Update running':'Start update'}</button></div>`;card.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});card.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const b=card.querySelector('.update');b.disabled=running(t.id)||!TARGET_UPDATEABLE(t);b.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});list.appendChild(card)}}
    function TARGET_UPDATEABLE(t){return ['ok','updates_available'].includes(t.check_status)}
    function rememberLogScroll(node){if(suppressLogScroll||!node.isConnected||node.id!==`log-${openJobLogId}`)return;const distance=node.scrollHeight-node.scrollTop-node.clientHeight;logAutoFollow=distance<=LOG_BOTTOM_TOLERANCE;logScrollTop=node.scrollTop;const latest=node.parentElement?.querySelector('.log-latest');if(latest)latest.hidden=logAutoFollow}
    function attachLogScroll(node){if(node.dataset.scrollAttached==='true')return;node.dataset.scrollAttached='true';node.addEventListener('scroll',()=>rememberLogScroll(node));}
    function createLogActions(node,unit){let actions=node.parentElement?.querySelector('.log-actions');if(!actions){actions=document.createElement('div');actions.className='log-actions';node.insertAdjacentElement('beforebegin',actions)}let download=actions.querySelector('.job-download');if(!download){download=document.createElement('a');download.className='job-download';download.dataset.downloadJob=unit;download.href=`/api/jobs/${encodeURIComponent(unit)}/download`;download.textContent='Download full log';actions.prepend(download)}return actions}
    function createLogLatest(node,unit){const actions=createLogActions(node,unit);let latest=actions.querySelector('.log-latest');if(latest)return latest;latest=document.createElement('button');latest.type='button';latest.className='log-latest';latest.textContent='Jump to latest';latest.hidden=true;latest.addEventListener('click',()=>{logAutoFollow=true;node.scrollTop=node.scrollHeight;logScrollTop=node.scrollTop;latest.hidden=true});actions.append(latest);return latest}
    async function loadJobLog(unit,node){const job=jobs.find(j=>j.unit===unit),final=job&&job.state!=='running';if(final&&finalLogLoaded.has(unit)||logLoading.has(unit))return;if(!final)finalLogLoaded.delete(unit);logLoading.add(unit);try{const d=await api(`/api/jobs/${encodeURIComponent(unit)}/log`);node.hidden=false;node.textContent=d.log||'(no journal output)';if(logAutoFollow){node.scrollTop=node.scrollHeight}else{node.scrollTop=logScrollTop}logScrollTop=node.scrollTop;const latest=node.parentElement?.querySelector('.log-latest');if(latest)latest.hidden=logAutoFollow;if(final)finalLogLoaded.add(unit)}catch(e){notice(e.message,true)}finally{logLoading.delete(unit)}}
    function renderJobs(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;n.hidden=false;suppressLogScroll=true;n.innerHTML='<div class="section-title"><h2>Jobs</h2><span class="hint">Server-side state · safe across browser/device changes</span></div>'+jobs.map(j=>{const open=j.unit===openJobLogId;return `<div class="job"><code>${esc(j.unit)}</code><span>${esc(friendlyJobTarget(j.target))}</span><span class="pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}">${esc(j.state)}</span><button data-job="${esc(j.unit)}">${open?'Hide log':'Show log'}</button><div class="log" id="log-${esc(j.unit)}"${open?'':' hidden'}></div></div>`}).join('');suppressLogScroll=false;n.querySelectorAll('button[data-job]').forEach(b=>b.addEventListener('click',async()=>{const unit=b.dataset.job;const node=document.getElementById(`log-${unit}`);if(openJobLogId===unit){openJobLogId=null;node.hidden=true;b.textContent='Show log';return}openJobLogId=unit;logAutoFollow=true;logScrollTop=0;node.hidden=false;b.textContent='Hide log';await loadJobLog(unit,node);attachLogScroll(node)}));if(openJobLogId){const node=document.getElementById(`log-${openJobLogId}`);if(node){node.scrollTop=logAutoFollow?node.scrollHeight:logScrollTop;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    async function loadStatus(){try{const d=await api('/api/status',{cache:'no-store'});try{render(d)}catch(e){console.error('Status render failed',e);if(!csrfToken)return;notice('The status view could not be rendered.',true);set('generated','Status render error');document.getElementById('targets').innerHTML='<div class="empty error">The status view could not be rendered.</div>'}}catch(e){if(!csrfToken)return;notice(e.message,true);set('generated','Status unavailable');document.getElementById('targets').innerHTML='<div class="empty">The status file is missing or invalid.</div>'}}
    function isStatusRefreshJob(job){return job?.type==='check'||job?.type==='update'}
    async function loadJobs(){try{const d=await api('/api/jobs',{cache:'no-store'}),previous=new Map(jobs.map(job=>[job.unit,job.state]));jobs=sortJobs(Array.isArray(d.jobs)?d.jobs:[]);const statusRefreshJobFinished=jobs.some(job=>isStatusRefreshJob(job)&&['completed','failed','interrupted'].includes(job.state)&&['running','pending','starting'].includes(previous.get(job.unit)));renderJobs();reorderJobDom();if(statusRefreshJobFinished)await loadStatus();clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,jobs.some(j=>j.state==='running')?2000:10000);render(currentStatus)}catch(e){clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,10000)}}
    let updaterVersion=null,versionRetryTimer=null,versionStartupTimer=null,versionRetryUsed=false;
    function versionDisplay(data,value,includeBranch=false){return value&&includeBranch&&data?.branch?`${value} · ${data.branch}`:(value||'Unavailable')}
    const shortCommit=value=>value&&/^[0-9a-f]{40}$/.test(value)?value.slice(0,7):(value||'Unknown');
    const versionFooterDisplay=data=>data?.state==='ok'?`${versionDisplay(data,data.installed,true)} · ${shortCommit(data.commit)}`:'version unavailable';
    function renderUpdaterVersion(data){updaterVersion=data;const label=document.getElementById('updater-version-label'),indicator=document.getElementById('updater-version-indicator'),updateButton=document.getElementById('updater-version-update');label.textContent=versionFooterDisplay(data);indicator.hidden=!(data.state==='ok'&&data.update_available===true);updateButton.disabled=!(data.state==='ok'&&data.update_available===true&&data.branch);updateButton.textContent=data.state==='ok'&&data.update_available===true?'Update now':'Up to date';const content=document.getElementById('updater-version-content');if(data.state!=='ok'){content.innerHTML='<p class="hint">Version check unavailable. Try again later.</p>';return}let rows=(data.components||[]).map(c=>`<tr><th>${esc(c.name)}</th><td>${esc(c.installed??c.local??'Unknown')}</td><td>${esc(c.available??c.server??'Unknown')}</td></tr>`).join('');content.innerHTML=`<div class="detail-grid"><div><span>Installed version</span><strong>${esc(versionDisplay(data,data.installed))}</strong></div><div><span>Available version</span><strong>${esc(versionDisplay(data,data.available))}</strong></div><div><span>Branch</span><strong>${esc(data.branch||'Unknown')}</strong></div><div><span>Commit</span><strong>${esc(shortCommit(data.commit))}</strong></div><div><span>Tag</span><strong>${esc(data.tag||'—')}</strong></div></div><table class="version-components"><thead><tr><th>Component</th><th>Installed</th><th>Available</th></tr></thead><tbody>${rows||'<tr><td colspan="3">No component details available.</td></tr>'}</tbody></table>`}
    async function loadUpdaterVersion(force=false){try{const data=await api(`/api/updater-version${force?'?force=1':''}`,{cache:'no-store'});renderUpdaterVersion(data);return data}catch(_error){const data={state:'unavailable',update_available:false,components:[]};renderUpdaterVersion(data);return data}}
    function scheduleUpdaterVersionCheck(){clearTimeout(versionStartupTimer);clearTimeout(versionRetryTimer);versionRetryUsed=false;versionStartupTimer=setTimeout(async()=>{const data=await loadUpdaterVersion();if(data.state==='unavailable'&&!versionRetryUsed){versionRetryUsed=true;versionRetryTimer=setTimeout(()=>loadUpdaterVersion(),7000)}},2500)}
    function openUpdaterVersion(){document.getElementById('updater-version-modal').classList.add('open')}
    document.getElementById('updater-version-indicator').onclick=openUpdaterVersion;document.getElementById('updater-version-footer').onclick=openUpdaterVersion;document.getElementById('updater-version-close').onclick=()=>document.getElementById('updater-version-modal').classList.remove('open');document.getElementById('updater-version-check').onclick=()=>loadUpdaterVersion(true);document.getElementById('updater-version-update').onclick=async()=>{if(!updaterVersion?.branch||updaterVersion.update_available!==true)return;const button=document.getElementById('updater-version-update');button.disabled=true;try{const data=await api('/api/updater-update',{method:'POST',body:JSON.stringify({branch:updaterVersion.branch})});document.getElementById('updater-version-message').textContent=data.message||'Updater self-update job started.';await loadJobs()}catch(error){document.getElementById('updater-version-message').textContent=error.message;document.getElementById('updater-version-message').className='management-message error';button.disabled=false}};
    document.getElementById('login-form').onsubmit=async event=>{event.preventDefault();const form=event.currentTarget;if(form.dataset.submitting==='true')return;const message=document.getElementById('login-message');message.className='management-message';message.textContent='';setLoginLoading(true);try{const r=await fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:form.elements.username.value,password:form.elements.password.value})});const d=await r.json();if(!r.ok)throw new Error('Login failed');csrfToken=d.csrf;form.reset();message.className='management-message success';message.textContent='Login successful';await Promise.all([loadStatus(),loadJobs(),loadTargets()]);showDashboard();scheduleUpdaterVersionCheck()}catch(error){setLoginLoading(false);message.className='management-message error';message.textContent='Login failed'}};
    document.getElementById('logout').onclick=async()=>{try{await api('/api/logout',{method:'POST',body:'{}'})}catch(_error){}showLogin('You have been signed out.')};
  </script>
  <div id="target-modal" class="modal-backdrop" role="dialog" aria-modal="true"><form id="target-modal-form" class="modal"><div style="display:flex;align-items:center;gap:10px"><h3 id="target-modal-title">External system</h3><button type="button" class="modal-close" id="target-modal-cancel">Close</button></div><div class="management-form open"><label>Name<input name="id" required pattern="[A-Za-z0-9][A-Za-z0-9_.-]*"></label><label>Host / IP<input name="host" required pattern="[A-Za-z0-9_.:-]+"></label><label>SSH user<input name="user" required pattern="[A-Za-z_][A-Za-z0-9_.-]*"></label><label>SSH port<input name="port" type="number" min="1" max="65535" value="22" required></label><div class="form-actions"><button type="submit" class="primary">Save</button><button type="button" id="target-modal-test">Test connection</button></div><div id="target-modal-message" class="management-message form-wide"></div></div></form></div>
  <script>
    let openNodes=new Set(), jobsExpanded=false, openDetailId=null;
    function jobSortValue(job){const parsed=Date.parse(job.started_at||job.finished_at||'');if(Number.isFinite(parsed))return parsed;const match=String(job.unit||'').match(/-(\d{8})-(\d{6})(?:-|$)/);if(match){const value=Date.parse(`${match[1].slice(0,4)}-${match[1].slice(4,6)}-${match[1].slice(6,8)}T${match[2].slice(0,2)}:${match[2].slice(2,4)}:${match[2].slice(4,6)}Z`);if(Number.isFinite(value))return value}return 0}
    function sortJobs(items){return [...items].sort((a,b)=>jobSortValue(b)-jobSortValue(a)||String(b.unit||'').localeCompare(String(a.unit||'')))}
    function reorderJobDom(){const list=document.querySelector('#jobs .job-list');if(!list)return;jobs.forEach(job=>{const item=[...list.children].find(candidate=>candidate.dataset.unit===job.unit);if(item)list.appendChild(item)})}
    const nodeLabel=t=>String(t.id||'').replace(/^host:/,'');
    const friendlyType=t=>({host:'Proxmox node',lxc:'LXC container',vm:'Virtual machine',external:'External system'}[String(t?.type||'').toLowerCase()]||String(t?.type||'Unknown'));
    const friendlyTarget=t=>{if(!t)return '';const type=String(t.type||'').toLowerCase();if(type==='host')return nodeLabel(t);if((type==='lxc'||type==='vm')&&t.name)return `${t.id} · ${t.name}`;return String(t.name||t.id||'').replace(/^host:/,'')};
    const friendlyJobTarget=target=>{const item=(currentStatus.targets||[]).find(candidate=>candidate&&String(candidate.id||'')===String(target||''));return item?friendlyTarget(item):String(target||'').replace(/^host:/,'')};
    const isProxmoxNode=t=>t&&t.type==='host'&&String(t.id||'').startsWith('host:');
    const nodeNameOrder=new Intl.Collator(undefined,{numeric:true,sensitivity:'base'});
    const sortNodes=items=>[...items].sort((a,b)=>nodeNameOrder.compare(nodeLabel(a),nodeLabel(b)));
    const targetNode=(t,nodes)=>t.node|| (nodes.length===1?nodeLabel(nodes[0]):null);
    const knownUpdates=t=>t.updates&&Number.isInteger(t.updates.available)?t.updates.available:null;
    const securitySplitSupported=t=>t?.security_split_supported===true||(!Object.prototype.hasOwnProperty.call(t||{},'security_split_supported')&&(t?.updater==='apt'||Object.prototype.hasOwnProperty.call(t||{},'normal_updates')||Object.prototype.hasOwnProperty.call(t||{},'security_updates')));
    const knownNormalUpdates=t=>securitySplitSupported(t)&&Number.isInteger(t?.normal_updates)?t.normal_updates:null;
    const knownSecurityUpdates=t=>securitySplitSupported(t)&&Number.isInteger(t?.security_updates)?t.security_updates:null;
    const knownTotalOnlyUpdates=t=>!securitySplitSupported(t)&&Number.isInteger(t?.updates?.available)?t.updates.available:null;
    const updateValue=value=>Number.isInteger(value)?String(value):'Unknown';
    const updateSummary=targets=>{const items=targets.filter(Boolean),normal=items.map(knownNormalUpdates),security=items.map(knownSecurityUpdates),other=items.map(knownTotalOnlyUpdates),knownNormal=normal.filter(Number.isInteger),knownSecurity=security.filter(Number.isInteger),knownOther=other.filter(Number.isInteger),parts=[];if(knownNormal.length)parts.push(`${knownNormal.reduce((a,v)=>a+v,0)} normal`);if(knownSecurity.length)parts.push(`${knownSecurity.reduce((a,v)=>a+v,0)} security`);if(knownOther.length)parts.push(`${knownOther.reduce((a,v)=>a+v,0)} other`);return items.length?(parts.length?parts.join(' · '):'Updates unknown'):'Updates unknown'};
    const osName=t=>{const value=text(t.os,'Unknown');return value==='Unknown'?value:value.charAt(0).toUpperCase()+value.slice(1)+(t.os_version?` ${t.os_version}`:'')};
    const statusTone=t=>{const [fallbackLabel,fallbackTone]=statusLabel(t.check_status),normal=knownNormalUpdates(t),security=knownSecurityUpdates(t),totalOnly=knownTotalOnlyUpdates(t),hasError=['bad'].includes(fallbackTone),securityClass=security!==null&&security>0&&!hasError?' security-warn':'';let label=fallbackLabel,tone=fallbackTone;if(!hasError){if(security!==null&&security>0){label='Security updates available';tone='warn'}else if((normal!==null&&normal>0)||(totalOnly!==null&&totalOnly>0)){label='Updates available';tone='warn'}else if((securitySplitSupported(t)&&normal===0&&security===0)||(!securitySplitSupported(t)&&totalOnly===0)){label='Healthy';tone='good'}else if(securitySplitSupported(t)&&normal===0&&security===null){label='Unknown';tone='neutral'}}return `<span class="pill ${tone}${securityClass}">${label}</span>`};
    const updateFields=t=>securitySplitSupported(t)?`<div><span>Normal updates</span><strong>${updateValue(knownNormalUpdates(t))}</strong></div><div><span>Security updates</span><strong>${updateValue(knownSecurityUpdates(t))}</strong></div>`:`<div><span>Updates</span><strong>${updateValue(knownTotalOnlyUpdates(t))}</strong></div>`;
    function closeDetails(){const n=document.getElementById('details');openDetailId=null;n.hidden=true;n.replaceChildren()}
    function renderDetails(t){const n=document.getElementById('details');if(openDetailId===t.id){closeDetails();return}const e=t.error?`${text(t.error.code,'')}${t.error.message?': '+t.error.message:''}`:'None',rebootDetail=t.type==='lxc'?'':`<div><span>Reboot required</span><strong class="${t.reboot_required===true?'reboot-required':''}">${t.reboot_required===null?'Unknown':t.reboot_required?'Yes':'No'}</strong></div>`,backup=t.type==='external'&&t.backup_status?text(t.backup_status.status,'Unknown'):'Not applicable';openDetailId=t.id;n.hidden=false;n.innerHTML=`<div class="details-heading"><h3>${esc(friendlyTarget(t))}</h3><button type="button" class="details-close">Close details</button></div><div class="detail-sections"><section><h4>System</h4><div class="detail-grid"><div><span>Type</span><strong>${esc(friendlyType(t))}</strong></div><div><span>Node</span><strong>${esc(t.node||'Not assigned')}</strong></div><div><span>Transport</span><strong>${esc(t.transport)}</strong></div><div><span>Operating system</span><strong>${esc(osName(t))}</strong></div></div></section><section><h4>Updates</h4><div class="detail-grid"><div><span>Updater</span><strong>${esc(t.updater)}</strong></div>${updateFields(t)}${rebootDetail}</div></section><section><h4>Status</h4><div class="detail-grid"><div><span>Check status</span><strong>${statusTone(t)}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div><div><span>Last update</span><strong>${esc(t.last_update&&t.last_update.status)}</strong></div><div><span>Backup safety</span><strong>${esc(backup)}</strong></div><div><span>Error</span><strong class="error-text">${esc(e)}</strong></div></div></section></div>`;n.querySelector('.details-close').onclick=closeDetails;n.scrollIntoView({behavior:'smooth',block:'nearest'})}
    function guestIdentity(t){return esc(friendlyTarget(t))}
    function toggleGroup(key){if(openNodes.has(key))openNodes.clear();else{openNodes.clear();openNodes.add(key)}render(currentStatus)}
    async function nodeAction(node,update=false){const key=`${update?'update':'check'}:${node}`,button=document.querySelector(`[data-node-action="${CSS.escape(key)}"]`);if(button?.disabled)return;if(update&&!confirm(`Update ${node}?\n\nOnly this Proxmox node will be updated. LXCs and VMs are not updated.`))return;document.querySelectorAll(`[data-node="${CSS.escape(node)}"]`).forEach(item=>{item.disabled=true});try{const d=await api(`/api/${update?'update-node':'check-node'}/${encodeURIComponent(node)}`,{method:'POST',body:'{}'});notice(d.message||'Action accepted.');await loadStatus();await loadJobs()}catch(error){notice(error.message,true)}finally{document.querySelectorAll(`[data-node="${CSS.escape(node)}"]`).forEach(item=>{item.disabled=false})}}
    async function refreshStatusSoon(attempt=0){if(attempt>=12)return;await new Promise(resolve=>setTimeout(resolve,2500));try{await loadStatus()}finally{refreshStatusSoon(attempt+1)}}
    function globalAction(update=false){const button=document.getElementById(update?'update-all':'check-all');if(button?.disabled)return;if(update){const ts=Array.isArray(currentStatus.targets)?currentStatus.targets:[],updates=ts.map(knownUpdates).filter(Number.isInteger).reduce((a,v)=>a+v,0),offline=ts.filter(t=>t.reachable===false).length;if(!confirm(`Update all systems?\n\n${updates} available updates are currently reported across the visible status. ${offline} system${offline===1?' is':'s are'} offline.\n\nConfigured update rules and safety checks will be respected.`))return}document.querySelectorAll('.global-action').forEach(item=>{item.disabled=true});button.textContent=update?'Starting updates…':'Starting check…';api(`/api/${update?'update-all':'check-all'}`,{method:'POST',body:'{}'}).then(async d=>{notice(d.message||'Action accepted.');await loadStatus();await loadJobs();refreshStatusSoon()}).catch(error=>notice(error.message,true)).finally(()=>{document.querySelectorAll('.global-action').forEach(item=>{item.disabled=false});button.textContent=update?'Update all systems':'Check all systems'})}
    function nodeGroup(node,guests,host){const open=openNodes.has(node),guestLabel=`${guests.length} guest${guests.length===1?'':'s'}`,rebootBadge=host?.reboot_required===true?'<span class="reboot-required-badge">Reboot required</span>':'',statusBadges=host?`${statusTone(host)}${rebootBadge}`:'',card=document.createElement('article');card.className=`node-group${open?' open':''}`;card.innerHTML=`<div class="group-header"><button class="group-toggle" type="button" aria-expanded="${open}" aria-label="${open?'Collapse':'Expand'} ${esc(node)}"><span class="chevron" aria-hidden="true"></span></button><div class="group-title"><strong>${esc(node)}</strong><small>Proxmox node</small></div>${host?`<div class="group-status">${statusBadges}</div>`:''}</div><div class="group-info"><span class="group-updates">${updateSummary((host?[host]:guests).filter(Boolean))} · ${guestLabel}</span></div><div class="group-actions"><button class="node-action node-check" data-node-action="check:${esc(node)}" data-node="${esc(node)}" type="button">Check node</button><button class="node-action node-update" data-node-action="update:${esc(node)}" data-node="${esc(node)}" type="button">Update node</button><button class="node-details">Details</button></div>`;card.querySelector('.group-header').addEventListener('click',e=>{if(e.target.closest('.group-toggle'))return;toggleGroup(node)});card.querySelector('.group-toggle').addEventListener('click',e=>{e.stopPropagation();toggleGroup(node)});card.querySelector('.node-details').addEventListener('click',e=>{e.stopPropagation();if(host)renderDetails(host)});card.querySelector('.node-check').addEventListener('click',e=>{e.stopPropagation();nodeAction(node)});card.querySelector('.node-update').addEventListener('click',e=>{e.stopPropagation();nodeAction(node,true)});let panel=null;if(open){panel=document.createElement('section');panel.className='guest-panel';panel.innerHTML=`<div class="guest-panel-title">Guests on ${esc(node)}</div><div class="guest-list"></div>`;guests.forEach(t=>panel.querySelector('.guest-list').appendChild(targetRow(t)))}return{card,panel}}
    function externalGroup(targets){const group=document.createElement('section');const open=openNodes.has('__external__');group.className=`external-group${open?' open':''}`;group.innerHTML=`<div class="group-header"><button class="group-toggle" type="button" aria-expanded="${open}" aria-label="${open?'Collapse':'Expand'} external systems"><span class="chevron" aria-hidden="true"></span></button><div class="group-title"><div><strong>External systems</strong><small>${targets.length} target${targets.length===1?'':'s'}</small></div></div><div class="group-summary"><span>${updateSummary(targets)}</span></div></div><div class="group-body"><div class="guest-list"></div></div>`;group.querySelector('.group-header').addEventListener('click',()=>toggleGroup('__external__'));group.querySelector('.group-toggle').addEventListener('click',e=>{e.stopPropagation();toggleGroup('__external__')});targets.forEach(t=>group.querySelector('.guest-list').appendChild(targetRow(t)));return group}
    function render(data){currentStatus=data;const ts=Array.isArray(data.targets)?data.targets:[],nodes=sortNodes(ts.filter(isProxmoxNode)),guests=ts.filter(t=>t.type==='lxc'||t.type==='vm'),external=ts.filter(t=>!isProxmoxNode(t)&&t.type!=='lxc'&&t.type!=='vm');set('total',ts.length);set('online',ts.filter(t=>t.reachable===true).length);set('attention',ts.filter(t=>t.check_status!=='ok').length);set('generated',`Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);const list=document.getElementById('targets');list.replaceChildren();if(!ts.length){list.innerHTML='<div class="empty">No target status is available yet. Run a check to populate the view.</div>';return}if(nodes.length){const grid=document.createElement('div');grid.className='node-grid';let openPanel=null,assigned=new Set();nodes.forEach(host=>{const node=nodeLabel(host),members=guests.filter(t=>targetNode(t,nodes)===node);members.forEach(t=>assigned.add(t.id));const parts=nodeGroup(node,members,host);grid.appendChild(parts.card);if(parts.panel)openPanel=parts.panel});const unassigned=guests.filter(t=>!assigned.has(t.id));if(unassigned.length){const parts=nodeGroup('Guests without node assignment',unassigned,null);grid.appendChild(parts.card);if(parts.panel)openPanel=parts.panel}list.appendChild(grid);if(openPanel)list.appendChild(openPanel)}else if(guests.length){const grid=document.createElement('div');grid.className='node-grid';const parts=nodeGroup('Guests without node assignment',guests,null);grid.appendChild(parts.card);list.appendChild(grid);if(parts.panel)list.appendChild(parts.panel)}if(external.length)list.appendChild(externalGroup(external))}
    function renderJobs(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;const runningCount=jobs.filter(j=>j.state==='running').length,finished=jobs.length-runningCount;n.hidden=false;suppressLogScroll=true;n.innerHTML=`<div class="section-title"><button class="job-toggle"><span class="chevron" aria-hidden="true"></span><span>Jobs <span class="job-count">(${runningCount} running, ${finished} finished)</span></span></button><span class="job-summary">Server-side state · safe across browser/device changes</span></div><div class="job-list"></div>`;suppressLogScroll=false;n.classList.toggle('collapsed',!jobsExpanded);n.querySelector('.job-toggle').addEventListener('click',()=>{jobsExpanded=!jobsExpanded;n.classList.toggle('collapsed',!jobsExpanded)});const list=n.querySelector('.job-list');jobs.forEach(j=>{const item=document.createElement('div');item.className='job';const open=j.unit===openJobLogId;item.innerHTML=`<code>${esc(j.unit)}</code><span>${esc(j.target)}</span><span class="pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}">${esc(j.state)}</span><button data-job="${esc(j.unit)}">${open?'Hide log':'Show log'}</button><div class="log" id="log-${esc(j.unit)}"${open?'':' hidden'}></div>`;list.appendChild(item)});n.querySelectorAll('button[data-job]').forEach(b=>b.addEventListener('click',async()=>{const unit=b.dataset.job,node=document.getElementById(`log-${unit}`);jobsExpanded=true;n.classList.remove('collapsed');if(openJobLogId===unit){openJobLogId=null;node.hidden=true;b.textContent='Show log';return}openJobLogId=unit;logAutoFollow=true;logScrollTop=0;node.hidden=false;b.textContent='Hide log';await loadJobLog(unit,node);attachLogScroll(node)}));if(openJobLogId){const node=document.getElementById(`log-${openJobLogId}`);if(node){node.scrollTop=logAutoFollow?node.scrollHeight:logScrollTop;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    document.getElementById('jobs').addEventListener('click',e=>{const button=e.target.closest('button[data-job]');if(button&&button.textContent==='Show log')finalLogLoaded.delete(button.dataset.job)},true);
    function renderRunningIndicator(){const indicator=document.getElementById('job-running-indicator'),label=document.getElementById('job-running-label'),runningJobs=jobs.filter(j=>j.state==='running');if(!indicator||!label)return;indicator.hidden=runningJobs.length===0;if(runningJobs.length)label.textContent=runningJobs.length===1?'Job running':`${runningJobs.length} jobs running`}
    document.getElementById('job-running-indicator').addEventListener('click',()=>{const section=document.getElementById('jobs');if(!section)return;jobsExpanded=true;section.classList.remove('collapsed');section.scrollIntoView({behavior:'smooth',block:'start'});const first=section.querySelector('.job[data-running="true"]');first?.scrollIntoView({behavior:'smooth',block:'nearest'})});
    function renderJobsStable(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;n.hidden=false;let list=n.querySelector('.job-list');if(!list||!n.querySelector('.job-toggle')){n.innerHTML='<div class="section-title"><button class="job-toggle"><span class="chevron" aria-hidden="true"></span><span>Jobs <span class="job-count"></span></span></button><span class="job-summary">Server-side state · safe across browser/device changes</span></div><div class="job-list"></div>';n.querySelector('.job-toggle').addEventListener('click',()=>{jobsExpanded=!jobsExpanded;n.classList.toggle('collapsed',!jobsExpanded)});list=n.querySelector('.job-list')}n.classList.toggle('collapsed',!jobsExpanded);n.querySelector('.job-count').textContent=`(${jobs.filter(j=>j.state==='running').length} running, ${jobs.filter(j=>j.state!=='running').length} finished)`;const existing=new Map([...list.querySelectorAll('.job')].map(item=>[item.dataset.unit,item]));const seen=new Set();for(const j of jobs){let item=existing.get(j.unit);if(!item){item=document.createElement('div');item.className='job';item.dataset.unit=j.unit;item.innerHTML=`<code></code><span></span><span class="pill"></span><button data-job="${esc(j.unit)}">Show log</button><div class="log" id="log-${esc(j.unit)}" hidden></div>`;const button=item.querySelector('button[data-job]');button.addEventListener('click',async()=>{const unit=button.dataset.job,node=document.getElementById(`log-${unit}`);if(openJobLogId===unit){openJobLogId=null;finalLogLoaded.delete(unit);node.hidden=true;item.querySelector('.log-actions')?.remove();button.textContent='Show log';return}if(openJobLogId&&openJobLogId!==unit){const previous=[...document.querySelectorAll('.job')].find(candidate=>candidate.dataset.unit===openJobLogId);previous?.querySelector('.log-actions')?.remove();const previousLog=previous?.querySelector('.log');if(previousLog)previousLog.hidden=true;const previousButton=previous?.querySelector('button[data-job]');if(previousButton)previousButton.textContent='Show log'}openJobLogId=unit;finalLogLoaded.delete(unit);logAutoFollow=true;logScrollTop=0;node.hidden=false;button.textContent='Hide log';createLogActions(node,unit);const latest=createLogLatest(node,unit);latest.hidden=true;await loadJobLog(unit,node);attachLogScroll(node)});list.appendChild(item)}seen.add(j.unit);item.querySelector('code').textContent=j.unit;item.querySelector('code').title=j.unit;item.querySelector('span').textContent=j.owner_node?`${friendlyJobTarget(j.target)} · ${j.owner_node}`:friendlyJobTarget(j.target);const state=item.querySelector('.pill');state.textContent=j.state;state.className=`pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}`;const button=item.querySelector('button[data-job]'),node=item.querySelector('.log'),open=j.unit===openJobLogId;button.textContent=open?'Hide log':'Show log';node.hidden=!open}for(const [unit,item] of existing){if(!seen.has(unit))item.remove()}if(openJobLogId){const job=jobs.find(j=>j.unit===openJobLogId),node=document.getElementById(`log-${openJobLogId}`);if(job&&node){node.hidden=false;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    renderJobs=renderJobsStable;window.renderJobs=renderJobsStable;
    function normalizeJobsHeading(){const toggle=document.querySelector('#jobs .job-toggle'),label=toggle?.querySelector('span:not(.chevron)');if(!label)return;const count=label.querySelector('.job-count');label.textContent='Jobs ';if(count)label.appendChild(count)}
    function decorateJobRows(){normalizeJobsHeading();const list=document.querySelector('#jobs .job-list');if(!list)return;for(const item of list.querySelectorAll('.job')){const job=jobs.find(candidate=>candidate.unit===item.dataset.unit);if(!job)continue;item.dataset.running=String(job.state==='running');const target=item.querySelector('span');if(target){const label=job.source==='initial-inventory'?'INITIAL INVENTORY':String(job.type||'update').toUpperCase();target.textContent=`${label} · ${job.owner_node?`${friendlyJobTarget(job.target)} · ${job.owner_node}`:friendlyJobTarget(job.target)}`}let meta=item.querySelector('.job-meta');if(!meta){meta=document.createElement('small');meta.className='job-meta';item.appendChild(meta)}const started=job.started_at?date(job.started_at):'Unknown';let duration='';if(job.started_at){const end=job.finished_at?Date.parse(job.finished_at):Date.now(),start=Date.parse(job.started_at);if(Number.isFinite(start)&&Number.isFinite(end))duration=` · ${Math.max(0,Math.round((end-start)/1000))}s`};meta.textContent=`Started ${started}${duration} · Exit ${job.exit_code===null||job.exit_code===undefined?'—':job.exit_code}`}}
    const renderJobsBase=renderJobs;renderJobs=function(){renderJobsBase();renderRunningIndicator();decorateJobRows()};window.renderJobs=renderJobs;
    document.getElementById('check-all').onclick=()=>globalAction(false);
    document.getElementById('update-all').onclick=()=>globalAction(true);
    clearTimeout(pollTimer);
  </script>
  <script>
    const configBooleanKeys=['CHECK_WITH_HOST','CHECK_WITH_LXC','CHECK_WITH_VM','CHECK_RUNNING_CONTAINER','CHECK_STOPPED_CONTAINER','CHECK_RUNNING_VM','CHECK_STOPPED_VM','CHECK_PAUSED_VM','WITH_HOST','WITH_LXC','WITH_VM','RUNNING_CONTAINER','STOPPED_CONTAINER','RUNNING_VM','STOPPED_VM','REBOOT_IF_NEEDED','EXIT_ON_ERROR','DEBUG','SNAPSHOT','BACKUP','BACKUP_LXC_MP','EMAIL_DAILY_CHECK','EMAIL_NO_UPDATES','EMAIL_ONLY_SECURITY','EMAIL_ONLY_ERROR','VERSION_CHECK','FREEBSD_UPDATES','INCLUDE_PHASED_UPDATES','INCLUDE_FSTRIM','FSTRIM_WITH_MOUNTPOINT','INCLUDE_HELPER_SCRIPTS','EXTRA_GLOBAL','IN_HEADLESS_MODE','PIHOLE','IOBROKER','PTERODACTYL','OCTOPRINT','DOCKER_COMPOSE','UNIFI'];
    const configNumberKeys=['SSH_PORT','LXC_START_DELAY','VM_START_DELAY','KEEP_SNAPSHOTS'];
    const configStringKeys=['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK','ONLY','EXCLUDE','BACKUP_MODE','BACKUP_STORAGE','EMAIL_USER','EMAIL_SENDER','EXE_FOR_INTERNET_CHECK','URL_FOR_INTERNET_CHECK','PACMAN_ENVIRONMENT','COMPOSE_PATH'];
    const configLabels={CHECK_WITH_HOST:'Check host',CHECK_WITH_LXC:'Check LXC',CHECK_WITH_VM:'Check VM',CHECK_RUNNING_CONTAINER:'Check running containers',CHECK_STOPPED_CONTAINER:'Check stopped containers',CHECK_RUNNING_VM:'Check running VMs',CHECK_STOPPED_VM:'Check stopped VMs',CHECK_PAUSED_VM:'Check paused VMs',WITH_HOST:'Update host',WITH_LXC:'Update LXC',WITH_VM:'Update VM',RUNNING_CONTAINER:'Update running containers',STOPPED_CONTAINER:'Update stopped containers',RUNNING_VM:'Update running VMs',STOPPED_VM:'Update stopped VMs',REBOOT_IF_NEEDED:'Reboot if needed',EXIT_ON_ERROR:'Continue after errors',DEBUG:'Debug logging',SNAPSHOT:'Create snapshots',KEEP_SNAPSHOTS:'Snapshots to keep',BACKUP:'Create backups',BACKUP_LXC_MP:'Backup LXC mount points',BACKUP_MODE:'Backup mode',BACKUP_STORAGE:'Backup storage',EMAIL_DAILY_CHECK:'Daily email check',EMAIL_NO_UPDATES:'Email when no updates',EMAIL_ONLY_SECURITY:'Email security updates only',EMAIL_ONLY_ERROR:'Email errors only',VERSION_CHECK:'Check for updater updates',SSH_PORT:'SSH port',EXE_FOR_INTERNET_CHECK:'Internet check command',URL_FOR_INTERNET_CHECK:'Internet check address',FREEBSD_UPDATES:'Update FreeBSD guests',INCLUDE_PHASED_UPDATES:'Include phased updates',INCLUDE_FSTRIM:'Run fstrim',FSTRIM_WITH_MOUNTPOINT:'Include mount points in fstrim',PACMAN_ENVIRONMENT:'Pacman environment',INCLUDE_HELPER_SCRIPTS:'Include helper scripts',EXTRA_GLOBAL:'Enable extra updates',IN_HEADLESS_MODE:'Run extras in headless mode',PIHOLE:'Update Pi-hole',IOBROKER:'Update ioBroker',PTERODACTYL:'Update Pterodactyl',OCTOPRINT:'Update OctoPrint',DOCKER_COMPOSE:'Update Docker Compose',UNIFI:'Update UniFi',COMPOSE_PATH:'Compose search path',LXC_START_DELAY:'LXC start delay',VM_START_DELAY:'VM start delay',ONLY_UPDATE_CHECK:'Only check filter',EXCLUDE_UPDATE_CHECK:'Exclude check filter',ONLY:'Only update filter',EXCLUDE:'Exclude update filter',EMAIL_USER:'Email recipient',EMAIL_SENDER:'Email sender'};
    const configGroups=[
      {title:'Host',hint:'Host checks and updates are controlled here. Guest settings below do not change host processing.',keys:['CHECK_WITH_HOST','WITH_HOST']},
      {title:'Containers / LXC',hint:'Choose which LXC guests and lifecycle states are included for checks and updates.',matrix:[{label:'Containers',check:'CHECK_WITH_LXC',update:'WITH_LXC'},{label:'Running containers',check:'CHECK_RUNNING_CONTAINER',update:'RUNNING_CONTAINER'},{label:'Stopped containers',check:'CHECK_STOPPED_CONTAINER',update:'STOPPED_CONTAINER'}],extras:['LXC_START_DELAY','BACKUP_LXC_MP']},
      {title:'Virtual Machines',hint:'Choose which VMs and lifecycle states are included for checks and updates.',matrix:[{label:'Virtual machines',check:'CHECK_WITH_VM',update:'WITH_VM'},{label:'Running VMs',check:'CHECK_RUNNING_VM',update:'RUNNING_VM'},{label:'Stopped VMs',check:'CHECK_STOPPED_VM',update:'STOPPED_VM'},{label:'Paused VMs',check:'CHECK_PAUSED_VM',update:null}],extras:['VM_START_DELAY']},
      {title:'Target filters',hint:'Check and update filters are independent. Only activates when an eligible target matches; with zero matches all eligible targets are used. Exclude is always applied afterwards.',filterGroups:[{title:'Check',keys:['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK'],preview:'check'},{title:'Update',keys:['ONLY','EXCLUDE'],preview:'update'}]},
      {title:'General update behavior',hint:'These options affect how the core processes checks and updates.',keys:['REBOOT_IF_NEEDED','EXIT_ON_ERROR','DEBUG','VERSION_CHECK','SSH_PORT','EXE_FOR_INTERNET_CHECK','URL_FOR_INTERNET_CHECK']},
      {title:'Advanced settings',hint:'Optional behavior for specialized guests and maintenance tasks.',keys:['FREEBSD_UPDATES','INCLUDE_PHASED_UPDATES','INCLUDE_FSTRIM','FSTRIM_WITH_MOUNTPOINT','PACMAN_ENVIRONMENT','INCLUDE_HELPER_SCRIPTS']},
      {title:'Extra updates',hint:'Optional service-specific updates. These apply only when extra updates are enabled.',keys:['EXTRA_GLOBAL','IN_HEADLESS_MODE','PIHOLE','IOBROKER','PTERODACTYL','OCTOPRINT','DOCKER_COMPOSE','UNIFI','COMPOSE_PATH']},
      {title:'Backup & safety',hint:'Configured protection is evaluated before guest updates.',keys:['SNAPSHOT','KEEP_SNAPSHOTS','BACKUP','BACKUP_MODE','BACKUP_STORAGE']},
      {title:'Notifications',hint:'Existing email notification settings only; no credentials are stored here.',keys:['EMAIL_DAILY_CHECK','EMAIL_NO_UPDATES','EMAIL_ONLY_SECURITY','EMAIL_ONLY_ERROR','EMAIL_USER','EMAIL_SENDER']}
    ];
    const helpContent={
      'Host':['Purpose: Select whether the Proxmox host is checked or updated. Default: both are enabled. Node actions always remain host-only; guest settings do not expand them.'],
      'Containers / LXC':['Purpose: Choose whether LXC containers are checked or updated and which running/stopped states are included. Defaults: all listed LXC checks/updates are enabled.','Start delay: seconds before a stopped LXC is checked or updated; default 5, and 0 means no extra delay. Backup mount points applies to backup protection, not checking.'],
      'Virtual Machines':['Purpose: Choose whether VMs are checked or updated and which running/stopped/paused states are included. Defaults: all listed VM checks/updates are enabled.','Start delay: seconds before a stopped QEMU VM is handled; default 45, and 0 means no extra delay. Paused VMs are never resumed by Initial Inventory.'],
      'Target filters':['Only names an optional Proxmox tag. It becomes active only when at least one eligible target matches it; with zero matches, all eligible targets are used.','Exclude always removes matching targets after the effective selection. Examples: check-exclude and update-exclude.','Only and Exclude are separate for checking and updating; the live preview uses the same selector as the runtime. Opening or changing the preview does not contact any target.'],
      'General update behavior':['Reboot if needed defaults to enabled; it permits the existing updater reboot-required handling and never makes the Web UI reboot a host automatically. Continue after errors defaults to disabled.','Debug logging shows additional technical output such as Proxmox commands, transport details and helper output. For normal operation it should usually remain disabled.','Version check defaults to enabled and only checks for newer Ultimate Updater code; it is not a system package check.','SSH port default: 22. It is the configured port for internal/remote updater SSH connections; VM-specific Internal SSH settings may override it.','Internet check defaults to command ping and address google.com. It runs before an update starts, retries briefly up to three times, and blocks the update if all attempts fail.'],
      'Advanced settings':['FreeBSD updates default to disabled and only affect supported FreeBSD/pfSense-style update paths. Linux package-manager behavior is not implied.','Phased updates default to disabled; when enabled, the existing apt update path may include packages held back by phased rollout.','Fstrim defaults to disabled. The mount-point option defaults to enabled and only matters when fstrim is enabled.','Pacman environment is an optional command prefix, for example env http_proxy=http://proxy:8080. Leave empty for no prefix. Helper scripts default to enabled and use the existing updater script locations.'],
      'Extra updates':['Extra updates default to enabled globally; individual services are enabled by default in the distributed configuration. A service is only processed when its own toggle is enabled.','Headless mode defaults to disabled and controls whether extra-update commands run without interactive output. Compose search path defaults to /home and may be set to another absolute path such as /opt.'],
      'Backup & safety':['Snapshots default to enabled, backups default to disabled, and three snapshots are kept by default. Protection is evaluated before a guest update.','Backup mode is limited to stop, suspend, or snapshot. stop gives highest consistency but causes downtime; suspend reduces downtime; snapshot is live and depends on supported storage.','Backup storage expects a Proxmox storage ID, not a filesystem path or PBS datastore name. Example: pbs. Leave it empty to use the first active backup storage reported by pvesm.'],
      'Notifications':['Email recipient defaults to root and the sender defaults to the system user. Daily checks are enabled by default; no-updates mail and security-only filtering are disabled by default.','These switches control existing notification selection only; they do not store SMTP credentials.']
    };
    const fieldHelpContent={
      SNAPSHOT:['Optional protection before a guest update. If snapshots are not supported for the guest or storage, the update continues without one; an unexpected snapshot error keeps the existing safety handling. An unsupported snapshot does not automatically enable a backup.'],
      BACKUP:['Optional protection that is independent of snapshots and runs only when enabled. A backup may take significantly longer depending on guest size and storage. Snapshot and backup can be enabled together, separately, or both disabled.'],
      BACKUP_MODE:['Controls the vzdump backup mode: stop, suspend, or snapshot. This is the backup mode and is separate from the Ultimate Updater Snapshot option.']
    };
    function closeHelpControls(except=null){document.querySelectorAll('.help-control.open').forEach(control=>{if(control!==except){control.classList.remove('open');control.querySelector('.help-trigger')?.setAttribute('aria-expanded','false')}})}
    function createHelpControl(label,paragraphs){const control=document.createElement('span');control.className='help-control';const id=`help-popover-${label.toLowerCase().replace(/[^a-z0-9]+/g,'-')}`;const button=document.createElement('button');button.className='help-trigger';button.type='button';button.textContent='?';button.setAttribute('aria-label',`About ${label}`);button.setAttribute('aria-expanded','false');button.setAttribute('aria-controls',id);button.addEventListener('click',event=>event.preventDefault());const popover=document.createElement('span');popover.id=id;popover.className='help-popover';popover.setAttribute('role','tooltip');paragraphs.forEach(text=>{const paragraph=document.createElement('p');paragraph.textContent=text;popover.appendChild(paragraph)});control.append(button,popover);return control}
    document.addEventListener('click',event=>{const trigger=event.target.closest('.help-trigger');if(trigger){const control=trigger.closest('.help-control'),open=control.classList.contains('open');closeHelpControls(control);control.classList.toggle('open',!open);trigger.setAttribute('aria-expanded',String(!open));return}if(!event.target.closest('.help-control'))closeHelpControls()});
    document.addEventListener('keydown',event=>{if(event.key!=='Escape')return;const open=document.querySelector('.help-control.open');closeHelpControls();if(open)open.querySelector('.help-trigger')?.focus()});
    let managedTargets=[], editingTarget=null, internalSshTargets=[], internalSshAvailable=[];
    function setConfigOpen(open){const form=document.getElementById('config-form'),panel=document.getElementById('config-panel'),button=document.getElementById('config-open');form.classList.toggle('open',open);document.querySelector('.management-grid').classList.toggle('config-open',open);button.textContent=open?'Close settings':'Open settings';button.setAttribute('aria-expanded',String(open));if(open)loadConfig()}
    function managementMessage(id,message,error=false){const n=document.getElementById(id);n.textContent=message||'';n.className=`management-message${error?' error':''}`}
    function configField(key,values,compact=false){const label=document.createElement('label');label.className=`config-field${configBooleanKeys.includes(key)?' boolean-field':''}${configNumberKeys.includes(key)?' numeric-field':''}${compact?' matrix-control':''}`;if(compact)label.title=configLabels[key]||key;const caption=document.createElement('span');caption.className='field-label';caption.textContent=configLabels[key]||key;if(!compact&&fieldHelpContent[key])caption.appendChild(createHelpControl(configLabels[key]||key,fieldHelpContent[key]));const input=key==='BACKUP_MODE'?document.createElement('select'):document.createElement('input');input.name=key;input.dataset.key=key;if(configBooleanKeys.includes(key)){input.type='checkbox';input.checked=values[key]===true;label.append(input,caption)}else if(key==='BACKUP_MODE'){const current=values[key]||'';['stop','suspend','snapshot'].forEach(option=>{const item=document.createElement('option');item.value=option;item.textContent=option;input.appendChild(item)});if(current&&!['stop','suspend','snapshot'].includes(current)){const item=document.createElement('option');item.value=current;item.textContent=`Legacy value: ${current}`;input.appendChild(item)}input.value=current||'stop';label.append(caption,input)}else{input.type=configNumberKeys.includes(key)?'number':'text';input.value=values[key]??'';if(input.type==='number'){input.min=key==='SSH_PORT'?'1':'0';if(key==='SSH_PORT')input.max='65535'}label.append(caption,input);if(configNumberKeys.includes(key)){const unit=document.createElement('span');unit.className='field-unit';unit.textContent=key==='KEEP_SNAPSHOTS'?'snapshots':key==='SSH_PORT'?'TCP port':'seconds';label.append(unit)}else if(key==='BACKUP_STORAGE'){const unit=document.createElement('span');unit.className='field-unit';unit.textContent='Proxmox storage ID, e.g. pbs';label.append(unit)}}return label}
    function configMatrix(groupData,values){const wrap=document.createElement('div');wrap.className='check-update-layout';const matrix=document.createElement('div');matrix.className='check-update-matrix';matrix.setAttribute('role','table');const header=document.createElement('div');header.className='matrix-row';const blank=document.createElement('span');blank.className='matrix-label';const checkHead=document.createElement('span');checkHead.className='matrix-cell matrix-head';checkHead.textContent='Check';const updateHead=document.createElement('span');updateHead.className='matrix-cell matrix-head';updateHead.textContent='Update';header.append(blank,checkHead,updateHead);matrix.appendChild(header);groupData.matrix.forEach(row=>{const item=document.createElement('div');item.className='matrix-row';const label=document.createElement('span');label.className='matrix-label';label.textContent=row.label;const check=document.createElement('span');check.className='matrix-cell';check.appendChild(configField(row.check,values,true));const update=document.createElement('span');update.className='matrix-cell';if(row.update)update.appendChild(configField(row.update,values,true));else{const dash=document.createElement('span');dash.className='matrix-empty';dash.textContent='—';update.appendChild(dash)}item.append(label,check,update);matrix.appendChild(item)});wrap.appendChild(matrix);if(groupData.extras){const extras=document.createElement('div');extras.className='matrix-extras';groupData.extras.forEach(key=>{const field=configField(key,values);if(configNumberKeys.includes(key)){const row=document.createElement('div');row.className='matrix-extra-row';const caption=field.querySelector('.field-label');caption.className='delay-label';const control=document.createElement('span');control.className='delay-control';control.append(field.querySelector('input'),field.querySelector('.field-unit'));row.append(caption,control);extras.appendChild(row)}else extras.appendChild(field)});wrap.appendChild(extras)}return wrap}
    const filterPreviewTimers={};
    function renderFilterPreview(data,scope){const box=document.getElementById(`${scope}-filter-preview`);if(!box)return;if(!data?.available){box.innerHTML='<div class="filter-preview-note">Target preview unavailable until the initial inventory has completed.</div>';return}const p=data.preview||{},included=p.included||[],excluded=p.excluded||[],onlyUnknown=p.only_unknown||[],excludeUnknown=p.exclude_unknown||[],configured=p.only_configured||'',matches=Number.isInteger(p.only_matches)?p.only_matches:0,active=Boolean(p.only_active);let summary=scope==='update'?`${included.length} targets selected for update`:`${included.length} targets selected for check`;const effective=active?`Only configured: ${esc(configured)} · matches: ${matches} · effective selection: only matching targets`:(configured?`Only tag "${esc(configured)}" has no eligible matches. Using all eligible targets.`:'Effective selection: all eligible targets');const detail=(title,items,klass)=>items.length?`<section><h4>${title}</h4><div class="filter-preview-list">${items.map(item=>`<div class="${klass||''}">${klass==='excluded'?'✕':'✓'} ${esc(item.label)}</div>`).join('')}</div></section>`:'';const unknownDetail=(title,items)=>items.length?`<section><h4>${title}</h4><div class="filter-preview-list"><div class="unknown">⚠ ${items.map(item=>`<span>${esc(item)}</span>`).join(', ')}</div></div></section>`:'';box.innerHTML=`<button type="button" class="filter-preview-toggle" aria-expanded="false"><span class="filter-preview-chevron" aria-hidden="true"></span><span>✓ ${summary}</span></button><div class="filter-preview-details"><section><h4>Selection</h4><div class="filter-preview-note">${effective} Exclude is always applied afterwards.</div></section>${detail(active?'Selected':'Included',included,'')}${detail('Excluded targets',excluded,'excluded')}${unknownDetail('Only tag not currently found',onlyUnknown)}${unknownDetail('Exclude tag not currently found',excludeUnknown)}</div>`;const toggle=box.querySelector('.filter-preview-toggle');toggle.onclick=()=>{const open=box.classList.toggle('open');toggle.setAttribute('aria-expanded',String(open))}}
    async function loadFilterPreview(form,scope){const keys=scope==='update'?['ONLY','EXCLUDE']:['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK'],only=form?.querySelector(`[data-key="${keys[0]}"]`)?.value||'',exclude=form?.querySelector(`[data-key="${keys[1]}"]`)?.value||'',box=document.getElementById(`${scope}-filter-preview`);if(box)box.innerHTML='<div class="filter-preview-note">Loading target preview…</div>';try{const query=new URLSearchParams({scope,only,exclude});const data=await api(`/api/config-preview?${query.toString()}`);renderFilterPreview(data,scope)}catch(error){if(box)box.innerHTML='<div class="filter-preview-note">Target preview is currently unavailable.</div>'}}
    function scheduleFilterPreview(form,scope){clearTimeout(filterPreviewTimers[scope]);filterPreviewTimers[scope]=setTimeout(()=>loadFilterPreview(form,scope),250)}
    function buildConfigForm(values){const form=document.getElementById('config-form');form.innerHTML='';form.dataset.initialConfig=JSON.stringify(values);for(const groupData of configGroups){const group=document.createElement('section');group.className='settings-group';const heading=document.createElement('div');heading.className='settings-heading';const title=document.createElement('h3');title.textContent=groupData.title;heading.appendChild(title);if(helpContent[groupData.title])heading.appendChild(createHelpControl(groupData.title,helpContent[groupData.title]));group.appendChild(heading);const hint=document.createElement('p');hint.textContent=groupData.hint;group.appendChild(hint);if(groupData.filterGroups){const scopes=document.createElement('div');scopes.className='filter-scopes';groupData.filterGroups.forEach(scopeData=>{const scope=document.createElement('section');scope.className='filter-scope';const scopeTitle=document.createElement('h4');scopeTitle.textContent=scopeData.title;scope.appendChild(scopeTitle);const fields=document.createElement('div');fields.className='config-fields';scopeData.keys.forEach(key=>fields.appendChild(configField(key,values)));scope.appendChild(fields);const preview=document.createElement('div');preview.id=`${scopeData.preview}-filter-preview`;preview.className='filter-preview';scope.appendChild(preview);scopes.appendChild(scope)});group.appendChild(scopes)}else if(groupData.matrix){group.appendChild(configMatrix(groupData,values))}else if(groupData.columns){const columns=document.createElement('div');columns.className='settings-columns';groupData.columns.forEach(keys=>{const column=document.createElement('div');column.className='settings-column';keys.forEach(key=>column.appendChild(configField(key,values)));columns.appendChild(column)});group.appendChild(columns)}else{const fields=document.createElement('div');fields.className='config-fields';groupData.keys.forEach(key=>fields.appendChild(configField(key,values)));group.appendChild(fields)}form.appendChild(group)}const actions=document.createElement('div');actions.className='config-actions';actions.innerHTML='<button type="submit" class="primary">Save settings</button><button type="button" id="config-close">Cancel</button>';form.appendChild(actions);form.querySelectorAll('[data-key="ONLY_UPDATE_CHECK"],[data-key="EXCLUDE_UPDATE_CHECK"]').forEach(input=>input.addEventListener('input',()=>scheduleFilterPreview(form,'check')));form.querySelectorAll('[data-key="ONLY"],[data-key="EXCLUDE"]').forEach(input=>input.addEventListener('input',()=>scheduleFilterPreview(form,'update')));loadFilterPreview(form,'check');loadFilterPreview(form,'update');form.onsubmit=async e=>{e.preventDefault();const initial=JSON.parse(form.dataset.initialConfig||'{}'),next={};for(const input of form.querySelectorAll('[data-key]')){const value=input.type==='checkbox'?input.checked:input.type==='number'?Number(input.value):input.value,previous=initial[input.dataset.key]??'';if(value!==previous)next[input.dataset.key]=value}if(!Object.keys(next).length){setConfigOpen(false);return}try{const d=await api('/api/config',{method:'POST',body:JSON.stringify({values:next})});buildConfigForm(d.config);setConfigOpen(false);managementMessage('config-message','Configuration saved.')}catch(error){managementMessage('config-message',error.message,true)}};document.getElementById('config-close').onclick=()=>setConfigOpen(false)}
    const buildConfigFormBase=buildConfigForm;buildConfigForm=function(values){buildConfigFormBase(values);const form=document.getElementById('config-form'),input=form?.querySelector('[data-key="EXIT_ON_ERROR"]');if(!input)return;input.checked=values.EXIT_ON_ERROR!==true;const submit=form.onsubmit;form.onsubmit=async event=>{input.checked=!input.checked;await submit.call(form,event);if(input.isConnected)input.checked=!input.checked}};
    async function loadConfig(){try{const d=await api('/api/config');buildConfigForm(d.config)}catch(error){managementMessage('config-message',error.message,true)}}
    function renderManagedTargets(){const box=document.getElementById('managed-targets');if(!managedTargets.length){box.innerHTML='<div class="empty">No external systems configured.</div>';return}box.innerHTML=managedTargets.map(t=>`<div class="managed-target"><div><strong>${esc(t.id)}</strong><small>${esc(t.user)}@${esc(t.host)}:${esc(t.port)} · SSH</small></div><div class="managed-actions"><button data-edit="${esc(t.id)}">Edit</button><button data-test="${esc(t.id)}">Test connection</button><button data-remove="${esc(t.id)}">Remove</button></div></div>`).join('');box.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>openTargetModal(managedTargets.find(t=>t.id===b.dataset.edit)));box.querySelectorAll('[data-test]').forEach(b=>b.onclick=()=>testTarget(b.dataset.test));box.querySelectorAll('[data-remove]').forEach(b=>b.onclick=()=>removeTarget(b.dataset.remove))}
    async function openExternalSettings(target){const form=document.getElementById('external-settings-form');form.elements.target.value=target;managementMessage('external-settings-message','Loading external settings…');document.getElementById('external-settings-modal').classList.add('open');try{const data=await api(`/api/external-settings/${encodeURIComponent(target)}`);const values=data.values||{};for(const key of ['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK','ONLY','EXCLUDE'])form.elements[key].value=values[key]??'';managementMessage('external-settings-message','These settings are stored on this external system.')}catch(error){managementMessage('external-settings-message',error.message,true)}}
    function closeExternalSettings(){document.getElementById('external-settings-modal').classList.remove('open')}
    async function saveExternalSettings(event){event.preventDefault();const form=event.currentTarget,target=form.elements.target.value,values={};for(const key of ['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK','ONLY','EXCLUDE'])values[key]=form.elements[key].value;try{await api(`/api/external-settings/${encodeURIComponent(target)}`,{method:'POST',body:JSON.stringify({values})});managementMessage('external-settings-message','External settings saved.')}catch(error){managementMessage('external-settings-message',error.message,true)}}
    const renderManagedTargetsBase=renderManagedTargets;renderManagedTargets=function(){renderManagedTargetsBase();const box=document.getElementById('managed-targets');box.querySelectorAll('.managed-actions').forEach(actions=>{const edit=actions.querySelector('[data-edit]');if(!edit)return;const settings=document.createElement('button');settings.type='button';settings.textContent='Settings';settings.dataset.settings=edit.dataset.edit;actions.insertBefore(settings,edit);settings.onclick=()=>openExternalSettings(settings.dataset.settings)})}
    function internalSshState(t){if(t.local)return 'Local · no SSH required';if(t.override)return t.enabled===false?'Internal SSH override · Disabled':'Internal SSH override';if(t.has_legacy_profile)return 'Existing SSH profile';return t.source||'QGA/default'}
    function renderInternalSsh(){const render=(kind,boxId,empty)=>{const box=document.getElementById(boxId),items=internalSshTargets.filter(t=>t.kind===kind);box.innerHTML=items.length?items.map(t=>{const state=internalSshState(t),disabled=t.override&&t.enabled===false;return `<div class="managed-target"><div><strong>${esc(kind==='node'?t.name:`${kind==='vm'?'VM':'CT'} ${t.id} · ${t.name||t.id}`)}</strong><small>${t.local?'Local · no SSH required':`${esc(t.host||'Not configured')} · ${esc(t.user)}:${esc(t.port)}`}</small><span class="ssh-state${disabled?' disabled':''}" data-ssh-state="${esc(t.kind)}:${esc(t.id)}">${esc(state)}</span><span class="ssh-test-feedback" data-ssh-feedback="${esc(t.kind)}:${esc(t.id)}" role="status"></span></div><div class="managed-actions">${t.local?'':`<button data-ssh-edit="${esc(t.kind)}:${esc(t.id)}">Edit SSH</button><button data-ssh-test="${esc(t.kind)}:${esc(t.id)}">Test connection</button>`}${t.override?`<button data-ssh-remove="${esc(t.kind)}:${esc(t.id)}">Remove override</button>`:''}</div></div>`}).join(''):`<div class="empty">${empty}</div>`};render('node','internal-ssh-nodes','No cluster nodes found.');render('vm','internal-ssh-vms','No additional VM SSH connections configured.');render('lxc','internal-ssh-lxcs','No additional LXC SSH connections configured.');document.querySelectorAll('[data-ssh-edit]').forEach(b=>b.onclick=()=>openInternalSsh(b.dataset.sshEdit));document.querySelectorAll('[data-ssh-test]').forEach(b=>b.onclick=()=>testInternalSsh(b.dataset.sshTest,b));document.querySelectorAll('[data-ssh-remove]').forEach(b=>b.onclick=()=>removeInternalSsh(b.dataset.sshRemove))}
    function internalSshLoadState(message,withRetry=false){for(const id of ['internal-ssh-nodes','internal-ssh-vms','internal-ssh-lxcs']){const box=document.getElementById(id);if(!box)continue;box.innerHTML=`<div class="empty error">${esc(message)}${withRetry?' <button type="button" class="internal-ssh-retry">Retry</button>':''}</div>`}document.querySelectorAll('.internal-ssh-retry').forEach(button=>button.onclick=loadInternalSsh)}
    async function loadInternalSsh(){internalSshLoadState('Loading…');try{const data=await api('/api/internal-ssh');internalSshTargets=data.targets||[];internalSshAvailable=data.available||[];renderInternalSsh()}catch(error){internalSshLoadState('Could not load Internal SSH connections.',true);managementMessage('internal-ssh-message',error.message,true)}}
    const mainViewElements=()=>['.dashboard-header','#notice','#systems','.management-grid','#jobs','footer'].map(selector=>document.querySelector(selector)).filter(Boolean);
    function setInternalSshView(open){mainViewElements().forEach(element=>{if(open){element.dataset.previousHidden=String(element.hidden);element.hidden=true}else if(element.dataset.previousHidden!==undefined){element.hidden=element.dataset.previousHidden==='true';delete element.dataset.previousHidden}});document.getElementById('internal-ssh-view').hidden=!open;if(open)loadInternalSsh()}
    function internalSshTargetLabel(t,includeNode=false){const label=t.kind==='node'?(t.name||t.id):`${t.kind==='vm'?'VM':'CT'} ${t.id} · ${t.name||t.id}`;return includeNode&&t.node?`${label} · ${t.node}`:label}
    function setInternalSshTargetPicker(form,visible){const picker=document.getElementById('internal-ssh-target-picker'),summary=document.getElementById('internal-ssh-target-summary');picker.hidden=!visible;summary.hidden=visible;picker.style.setProperty('display',visible?'':'none','important');summary.style.setProperty('display',visible?'none':'grid','important');form.elements.target_choice.disabled=!visible;form.elements.target_choice.required=visible}
    function openInternalSsh(key){const [kind,id]=key.split(':',2),t=internalSshTargets.find(item=>item.kind===kind&&item.id===id),form=document.getElementById('internal-ssh-form');if(!t)return;form.dataset.mode='edit';form.dataset.targetKey=key;form.elements.kind.value=kind;form.elements.id.value=id;form.elements.target_choice.value='';form.elements.host.value=t.host||'';form.elements.user.value=t.user||'root';form.elements.port.value=t.port||22;form.elements.identity_file.value=t.identity_file||'';form.elements.enabled.checked=t.enabled!==false;setInternalSshTargetPicker(form,false);document.getElementById('internal-ssh-title').textContent='Edit SSH settings';const summary=document.getElementById('internal-ssh-target-summary');summary.querySelector('span').textContent=internalSshTargetLabel({kind,id,name:t.name||id});document.getElementById('internal-ssh-save').textContent='Save SSH settings';document.getElementById('internal-ssh-remove').hidden=!t.override;document.getElementById('internal-ssh-form-message').textContent='';document.getElementById('internal-ssh-modal').classList.add('open')}
    function openInternalSshAdd(kind){const form=document.getElementById('internal-ssh-form'),choices=internalSshAvailable.filter(item=>item.kind===kind),picker=form.elements.target_choice;picker.innerHTML=choices.map(t=>`<option value="${esc(t.kind)}:${esc(t.id)}">${esc(internalSshTargetLabel(t,true))}</option>`).join('');if(!choices.length){managementMessage('internal-ssh-message',`No unconfigured ${kind==='vm'?'VM':'LXC'} systems are available.`);return}const applyChoice=()=>{const choice=choices.find(item=>`${item.kind}:${item.id}`===picker.value)||choices[0];form.elements.kind.value=choice.kind;form.elements.id.value=choice.id;form.elements.host.value=choice.host||'';form.elements.user.value=choice.user||'root';form.elements.port.value=choice.port||22};form.dataset.mode='add';setInternalSshTargetPicker(form,true);picker.onchange=applyChoice;picker.value=`${choices[0].kind}:${choices[0].id}`;applyChoice();form.elements.identity_file.value='';form.elements.enabled.checked=true;document.getElementById('internal-ssh-title').textContent=`Add ${kind==='vm'?'VM':'LXC'} SSH connection`;document.getElementById('internal-ssh-remove').hidden=true;document.getElementById('internal-ssh-save').textContent='Add SSH connection';document.getElementById('internal-ssh-form-message').textContent='';document.getElementById('internal-ssh-modal').classList.add('open')}
    function closeInternalSsh(){document.getElementById('internal-ssh-modal').classList.remove('open')}
    async function testInternalSsh(key,button){const [kind,id]=key.split(':'),feedback=button?.closest('.managed-target')?.querySelector('[data-ssh-feedback]');if(feedback){feedback.className='ssh-test-feedback';feedback.textContent='Testing connection…'}if(button)button.disabled=true;try{const d=await api(`/api/internal-ssh/${encodeURIComponent(kind)}/${encodeURIComponent(id)}/test`,{method:'POST',body:'{}'});if(feedback){feedback.className='ssh-test-feedback success';feedback.textContent=d.message||'Connection successful.'}managementMessage('internal-ssh-message',d.message||'Connection successful.')}catch(error){if(feedback){feedback.className='ssh-test-feedback error';feedback.textContent=error.message||'Connection failed.'}managementMessage('internal-ssh-message',error.message||'Connection failed.',true)}finally{if(button)button.disabled=false}}
    async function removeInternalSsh(key){const [kind,id]=key.split(':');if(!confirm('Remove this override and restore automatic/default resolution?'))return;try{await api(`/api/internal-ssh/${encodeURIComponent(kind)}/${encodeURIComponent(id)}`,{method:'DELETE'});await loadInternalSsh();managementMessage('internal-ssh-message','Override removed; default resolution restored.')}catch(error){managementMessage('internal-ssh-message',error.message,true)}}
    document.getElementById('internal-ssh-form').onsubmit=async event=>{event.preventDefault();const f=event.currentTarget,values={host:f.elements.host.value,user:f.elements.user.value,port:Number(f.elements.port.value),enabled:f.elements.enabled.checked};if(f.elements.identity_file.value)values.identity_file=f.elements.identity_file.value;try{await api(`/api/internal-ssh/${encodeURIComponent(f.elements.kind.value)}/${encodeURIComponent(f.elements.id.value)}`,{method:'POST',body:JSON.stringify({values})});closeInternalSsh();await loadInternalSsh();managementMessage('internal-ssh-message','Internal SSH override saved.')}catch(error){managementMessage('internal-ssh-form-message',error.message,true)}};
    document.getElementById('internal-ssh-close').onclick=closeInternalSsh;document.getElementById('internal-ssh-remove').onclick=()=>removeInternalSsh(`${document.querySelector('#internal-ssh-form [name=kind]').value}:${document.querySelector('#internal-ssh-form [name=id]').value}`);document.querySelectorAll('[data-ssh-add]').forEach(b=>b.onclick=()=>openInternalSshAdd(b.dataset.sshAdd));
    async function loadTargets(){try{managedTargets=(await api('/api/targets')).targets||[];renderManagedTargets()}catch(error){managementMessage('target-message',error.message,true)}}
    function openTargetModal(target=null){editingTarget=target;const form=document.getElementById('target-modal-form');form.reset();form.elements.id.value=target?.id||'';form.elements.host.value=target?.host||'';form.elements.user.value=target?.user||'root';form.elements.port.value=target?.port||22;form.elements.id.readOnly=Boolean(target);document.getElementById('target-modal-title').textContent=target?'Edit external system':'Add external system';managementMessage('target-modal-message','');document.getElementById('target-modal').classList.add('open')}
    function closeTargetModal(){document.getElementById('target-modal').classList.remove('open');editingTarget=null}
    async function saveTarget(e){e.preventDefault();const form=e.currentTarget;const payload={id:form.elements.id.value,host:form.elements.host.value,user:form.elements.user.value,port:Number(form.elements.port.value)};try{await api(editingTarget?`/api/targets/${encodeURIComponent(editingTarget.id)}`:'/api/targets',{method:editingTarget?'PUT':'POST',body:JSON.stringify(payload)});closeTargetModal();await loadTargets();await loadStatus();managementMessage('target-message','External target saved.')}catch(error){managementMessage('target-modal-message',error.message,true)}}
    async function removeTarget(id){if(!confirm(`Remove external system "${id}"?`))return;try{await api(`/api/targets/${encodeURIComponent(id)}`,{method:'DELETE'});await loadTargets();await loadStatus();managementMessage('target-message','External target removed.')}catch(error){managementMessage('target-message',error.message,true)}}
    async function testTarget(id){try{const d=await api(`/api/targets/${encodeURIComponent(id)}/test`,{method:'POST',body:'{}'});const t=d.target||{};managementMessage('target-message',`Connection successful · ${t.os||'OS unknown'} · ${t.updater||'updater unknown'}`)}catch(error){managementMessage('target-message',error.message,true)}}
    function targetRow(t){const rebootField=t.type==='lxc'?'':`<div class="target-field"><span class="target-label">Reboot</span><strong class="${t.reboot_required===true?'reboot-required':''}">${t.reboot_required===true?'Yes':t.reboot_required===false?'No':'Unknown'}</strong></div>`;const row=document.createElement('div');row.className=`target-row ${securitySplitSupported(t)?'split-row':'total-only-row'}`;if(t.type==='lxc')row.classList.add('lxc-row');row.innerHTML=`<div><div class="target-name">${guestIdentity(t)}</div><div class="target-id">${esc(t.type)} · ${esc(t.transport)}</div></div><div class="target-field target-status">${statusTone(t)}</div>${securitySplitSupported(t)?`<div class="target-field"><span class="target-label">Normal</span><strong>${updateValue(knownNormalUpdates(t))}</strong></div><div class="target-field"><span class="target-label">Security</span><strong>${updateValue(knownSecurityUpdates(t))}</strong></div>`:`<div class="target-field"><span class="target-label">Updates</span><strong>${updateValue(knownTotalOnlyUpdates(t))}</strong></div>`}${rebootField}<div class="target-field row-os"><span class="target-label">OS</span><strong>${esc(osName(t))}</strong></div><div class="target-field row-last-check"><span class="target-label">Last check</span><strong>${esc(date(t.last_check))}</strong></div><div class="row-actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Running':'Update'}</button></div>`;row.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});row.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const update=row.querySelector('.update');update.disabled=running(t.id)||!TARGET_UPDATEABLE(t);update.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});return row}
    document.getElementById('config-open').onclick=()=>setConfigOpen(!document.getElementById('config-form').classList.contains('open'));document.getElementById('internal-ssh-open').onclick=()=>setInternalSshView(true);document.getElementById('internal-ssh-back').onclick=()=>setInternalSshView(false);document.getElementById('target-add').onclick=()=>openTargetModal();document.getElementById('target-modal-cancel').onclick=closeTargetModal;document.getElementById('target-modal-test').onclick=()=>{const id=document.querySelector('#target-modal-form [name=id]').value;if(id)testTarget(id)};document.getElementById('target-modal-form').onsubmit=saveTarget;document.getElementById('external-settings-close').onclick=closeExternalSettings;document.getElementById('external-settings-form').onsubmit=saveExternalSettings;
    async function bootstrap(){try{await ensureSession();await Promise.all([loadStatus(),loadJobs(),loadTargets()]);showDashboard();scheduleUpdaterVersionCheck()}catch(error){if(csrfToken)notice(error.message,true)}}
    const aggregateField=field=>{const targets=Array.isArray(currentStatus?.targets)?currentStatus.targets:[],values=targets.map(t=>t?.[field]).filter(Number.isInteger);return values.length?values.reduce((sum,value)=>sum+value,0):null};
    const aggregateTotalOnly=()=>{const targets=Array.isArray(currentStatus?.targets)?currentStatus.targets:[],values=targets.map(knownTotalOnlyUpdates).filter(Number.isInteger);return values.length?values.reduce((sum,value)=>sum+value,0):null};
    const aggregateFieldComplete=field=>{const targets=Array.isArray(currentStatus?.targets)?currentStatus.targets:[];return targets.length&&targets.every(t=>Number.isInteger(t?.[field])||!securitySplitSupported(t))?aggregateField(field):null};
    const renderWithSplitSummary=render;
    render=function(data){renderWithSplitSummary(data);const normal=aggregateField('normal_updates'),security=aggregateFieldComplete('security_updates'),other=aggregateTotalOnly();set('normal-updates',normal===null?'Unknown':normal);set('security-updates',security===null?'Unknown':security);set('other-updates',other===null?'0':other)};
    bootstrap();
  </script>
</main></body></html>"""

# Keep the jobs view neutral: it contains checks as well as updates.  The
# replacement also covers the legacy render path kept for compatibility with
# older browser state; the active renderer adds CHECK/UPDATE labels per row.
PAGE = PAGE.replace("Update jobs", "Jobs")


def error_payload(code, message):
    return {"error": {"code": code, "message": message}}


def parse_state_line(line):
    fields = line.rstrip("\n").split("\t")
    if len(fields) < 6:
        return None
    unit, target, state, started, finished, exit_code = fields[:6]
    source = None
    if len(fields) > 8:
        source = fields[8] or None
    if len(fields) > 7:
        job_type = fields[6] or "update"
        owner_node = fields[7] or None
    elif len(fields) > 6:
        if fields[6] in {"check", "update", ""}:
            job_type = fields[6] or "update"
            owner_node = None
        else:
            job_type = "update"
            owner_node = fields[6]
    else:
        job_type = "update"
        owner_node = None
    return {"unit": unit, "target": target, "state": state,
            "started_at": started or None, "finished_at": finished or None,
            "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else None,
            "type": job_type if job_type in {"check", "update", "selfupdate"} else "update",
            "source": source, "owner_node": owner_node, "remote": owner_node is not None}


def parse_updater_version_output(output):
    """Parse the existing update.sh status table without duplicating its sources."""
    clean = strip_ansi(output)
    branch_match = re.search(r"Version overview \((master|beta|develop)\)", clean, re.IGNORECASE)
    branch = branch_match.group(1).lower() if branch_match else None
    installed_commit_match = re.search(r"^Installed commit:\s*(\S+)", clean, re.MULTILINE | re.IGNORECASE)
    available_commit_match = re.search(r"^Available commit:\s*(\S+)", clean, re.MULTILINE | re.IGNORECASE)
    tag_match = re.search(r"^Installed tag:\s*(\S+)", clean, re.MULTILINE | re.IGNORECASE)
    installed_commit = installed_commit_match.group(1) if installed_commit_match else "unknown"
    available_commit = available_commit_match.group(1) if available_commit_match else "unknown"
    installed_tag = tag_match.group(1) if tag_match and tag_match.group(1) not in {"—", "-"} else None
    components = []
    for line in clean.splitlines():
        match = re.match(r"^\s*(Updater|Extras|Config|Welcome|Check)\s+(\S+)\s+(\S+)\s*$", line)
        if match:
            components.append({"name": match.group(1), "local": match.group(2), "server": match.group(3),
                               "installed": match.group(2), "available": match.group(3)})
    updater = next((item for item in components if item["name"] == "Updater"), None)
    installed = updater["local"] if updater else None
    available = updater["server"] if updater else None
    numeric = lambda value: tuple(int(part) for part in value.split(".") if part.isdigit()) if value and re.fullmatch(r"\d+(?:\.\d+)*", value) else None
    local_numbers, remote_numbers = numeric(installed), numeric(available)
    version_update = bool(local_numbers is not None and remote_numbers is not None and remote_numbers > local_numbers)
    commit_update = bool(re.fullmatch(r"[0-9a-f]{40}", installed_commit) and
                         re.fullmatch(r"[0-9a-f]{40}", available_commit) and
                         installed_commit != available_commit)
    return {
        "state": "ok" if branch and updater and updater["server"] != "unavailable" else "unavailable",
        "branch": branch,
        "installed": installed,
        "available": available,
        "commit": installed_commit,
        "available_commit": available_commit,
        "tag": installed_tag,
        "update_available": version_update or commit_update,
        "components": components,
    }


def parse_config_text(content):
    values = {}
    for line in content.splitlines():
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)(?:\s+#.*)?$", line)
        if not match or match.group(1) not in CONFIG_KEYS:
            continue
        raw = match.group(2).strip()
        try:
            parsed = shlex.split(raw, comments=False, posix=True)
        except ValueError:
            parsed = []
        values[match.group(1)] = parsed[0] if parsed else raw.strip("\"'")
    return values


def config_value_map(content):
    values = parse_config_text(content)
    result = {}
    for key in sorted(CONFIG_KEYS):
        value = values.get(key)
        if key in CONFIG_BOOLEAN_KEYS and value is not None:
            result[key] = value.lower() == "true"
        elif key in CONFIG_INTEGER_KEYS and value is not None and value.isdigit():
            result[key] = int(value)
        else:
            result[key] = value
    return result


EXTERNAL_SETTING_KEYS = ("ONLY_UPDATE_CHECK", "EXCLUDE_UPDATE_CHECK", "ONLY", "EXCLUDE")


def parse_internal_ssh_text(content):
    values = {}
    section = None
    for number, raw in enumerate(content.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line == "schema_version=1" and section is None:
            continue
        match = re.fullmatch(r"\[(node|vm|lxc):([A-Za-z0-9_.:-]+)\]", line)
        if match:
            section = f"{match.group(1)}:{match.group(2)}"
            if section in values:
                raise ValueError(f"duplicate section at line {number}")
            values[section] = {}
            continue
        if section is None or "=" not in line:
            raise ValueError(f"invalid internal SSH config line {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in {"host", "user", "port", "identity_file", "enabled"} or key in values[section]:
            raise ValueError(f"unsupported or duplicate internal SSH key at line {number}")
        if "\n" in value or "\r" in value or len(value) > 1024:
            raise ValueError("invalid internal SSH value")
        if key == "host" and not HOST_RE.fullmatch(value):
            raise ValueError("invalid internal SSH host")
        if key == "user" and not USER_RE.fullmatch(value):
            raise ValueError("invalid internal SSH user")
        if key == "port" and (not value.isdigit() or not 1 <= int(value) <= 65535):
            raise ValueError("invalid internal SSH port")
        if key == "identity_file" and (not value.startswith("/") or "\n" in value):
            raise ValueError("identity_file must be an absolute path")
        if key == "enabled" and value not in {"true", "false"}:
            raise ValueError("invalid internal SSH enabled value")
        values[section][key] = value
    return values


def internal_ssh_text(values):
    lines = ["# Internal SSH overrides for Proxmox nodes and internal VMs.",
             "# This file is data, not a shell script.", "schema_version=1", ""]
    for section in sorted(values):
        lines.append(f"[{section}]")
        for key in ("host", "user", "port", "identity_file", "enabled"):
            if key in values[section]:
                lines.append(f"{key}={values[section][key]}")
        lines.append("")
    return "\n".join(lines)


def parse_external_config_text(content):
    values = {}
    schema = None
    for line in content.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise ValueError("invalid External config line")
        key, raw = line.split("=", 1)
        key = key.strip()
        if key == "schema_version":
            if schema is not None:
                raise ValueError("duplicate External schema")
            schema = raw.strip().strip("\"'")
            if schema != "1":
                raise ValueError("unsupported External config schema")
            continue
        if key not in EXTERNAL_SETTING_KEYS or key in values:
            raise ValueError("unsupported or duplicate External setting")
        if "\n" in raw or "\r" in raw or len(raw) > 513:
            raise ValueError("invalid External setting value")
        try:
            parsed = shlex.split(raw, comments=False, posix=True)
        except ValueError as error:
            raise ValueError("invalid External setting value") from error
        values[key] = parsed[0] if parsed else raw.strip("\"'")
    if schema != "1":
        raise ValueError("External config schema is missing")
    return {key: values.get(key, "") for key in EXTERNAL_SETTING_KEYS}


def validate_config_values(values):
    if not isinstance(values, dict) or not values:
        raise ValueError("No configuration values were supplied.")
    unknown = set(values) - CONFIG_KEYS
    if unknown:
        raise ValueError("Unsupported configuration key: " + sorted(unknown)[0])
    normalized = {}
    for key, value in values.items():
        if key in CONFIG_BOOLEAN_KEYS:
            if not isinstance(value, bool):
                raise ValueError(f"{key} must be boolean.")
            normalized[key] = "true" if value else "false"
        elif key in CONFIG_INTEGER_KEYS:
            minimum = 1 if key == "SSH_PORT" else 0
            maximum = 65535 if key == "SSH_PORT" else None
            if (isinstance(value, bool) or not isinstance(value, int) or value < minimum or
                    maximum is not None and value > maximum):
                if maximum is None:
                    raise ValueError(f"{key} must be a non-negative integer.")
                raise ValueError(f"{key} must be an integer between {minimum} and {maximum}.")
            normalized[key] = str(value)
        elif key in CONFIG_ENUMS:
            if not isinstance(value, str) or value not in CONFIG_ENUMS[key]:
                allowed = ", ".join(sorted(CONFIG_ENUMS[key]))
                raise ValueError(f"{key} must be one of: {allowed}.")
            normalized[key] = value
        else:
            if not isinstance(value, str) or "\n" in value or "\r" in value or len(value) > 512:
                raise ValueError(f"{key} must be a short single-line value.")
            if key == "BACKUP_STORAGE" and value and not re.fullmatch(r"[A-Za-z0-9_.-]+", value):
                raise ValueError("BACKUP_STORAGE contains unsupported characters.")
            normalized[key] = value
    return normalized


def update_config_text(content, normalized):
    lines = content.splitlines(keepends=True)
    found = set()
    output = []
    for line in lines:
        match = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*=\s*)(\"[^\"]*\"|'[^']*'|[^#\s]*)(.*?)(\r?\n)?$", line)
        if not match or match.group(2) not in normalized:
            output.append(line)
            continue
        key = match.group(2)
        found.add(key)
        tail = match.group(5) or ""
        output.append(f"{match.group(1)}{key}{match.group(3)}{json.dumps(normalized[key])}{tail}{match.group(6) or ''}")
    if output and not output[-1].endswith("\n"):
        output[-1] += "\n"
    for key in normalized:
        if key not in found:
            output.append(f"{key}={json.dumps(normalized[key])}\n")
    return "".join(output)


def parse_inventory_text(content):
    sections = []
    current = None
    for line in content.splitlines(keepends=True):
        section_match = re.match(r"^\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?(?:\r?\n)?$", line)
        if section_match:
            current = {"id": section_match.group(1), "lines": [line], "values": {}}
            sections.append(current)
            continue
        if current is not None:
            current["lines"].append(line)
            key_match = re.match(r"^\s*(host|port|transport|user)\s*=\s*([^#\r\n]*?)\s*(?:#.*)?(?:\r?\n)?$", line)
            if key_match:
                current["values"][key_match.group(1)] = key_match.group(2).strip()
    return sections


def inventory_payload(content):
    result = []
    for section in parse_inventory_text(content):
        values = section["values"]
        result.append({"id": section["id"], "host": values.get("host", ""),
                       "user": values.get("user", "root"),
                       "port": int(values.get("port", "22")),
                       "transport": values.get("transport", "ssh")})
    return result


def project_active_status(payload, active_external_ids):
    """Keep historical status data out of the active Systems projection."""
    if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
        raise ValueError("Status payload has no target list.")
    active_ids = set(active_external_ids)
    projected = dict(payload)
    projected["targets"] = [
        target for target in payload["targets"]
        if not isinstance(target, dict)
        or target.get("type") != "external"
        or target.get("id") in active_ids
    ]
    return projected


def external_backup_status(state_file, target, max_age=86400):
    """Read local, time-bound manual backup verification without contacting targets."""
    try:
        with Path(state_file).open(encoding="utf-8") as source:
            state = json.load(source)
        record = state.get(target, {}) if isinstance(state, dict) else {}
    except (OSError, UnicodeError, json.JSONDecodeError):
        record = {}
    result = {
        "status": "unknown",
        "verified_at": record.get("verified_at") if isinstance(record, dict) else None,
        "verified_by": record.get("verified_by") if isinstance(record, dict) else None,
        "reference": record.get("reference", "") if isinstance(record, dict) else "",
        "age_seconds": None,
    }
    if isinstance(result["verified_at"], str):
        try:
            verified = datetime.fromisoformat(result["verified_at"].replace("Z", "+00:00"))
            seconds = int((datetime.now(timezone.utc) - verified).total_seconds())
            result["age_seconds"] = max(0, seconds)
            result["status"] = "verified" if 0 <= seconds <= max_age else "expired"
        except ValueError:
            pass
    return result


def active_inventory_projection(payload, inventory):
    """Return the canonical active target set for status and filter preview."""
    active_external_ids = {
        item["id"] for item in inventory if item.get("transport") == "ssh"
    }
    projected = project_active_status(payload, active_external_ids)
    known_ids = {
        str(item.get("id", "")) for item in projected["targets"]
    }
    for item in inventory:
        if item.get("transport") != "ssh" or item["id"] in known_ids:
            continue
        projected["targets"].append({
            "id": item["id"],
            "type": "external",
            "transport": item["transport"],
            "name": item["id"],
            "reachable": None,
            "os": None,
            "updater": None,
            "updates": {"available": None},
            "reboot_required": None,
            "last_check": None,
            "check_status": "unknown",
            "error": None,
            "node": None,
        })
    return projected


def proxmox_inventory_snapshot(runner=subprocess.run):
    """Read the local Proxmox inventory without contacting any guest target."""
    try:
        result = runner(
            ["pvesh", "get", "/cluster/resources", "--type", "vm", "--output-format", "json"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        nodes = runner(
            ["pvesh", "get", "/cluster/resources", "--type", "node", "--output-format", "json"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if result.returncode or nodes.returncode:
            return None
        resources = json.loads(result.stdout)
        node_resources = json.loads(nodes.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if not isinstance(resources, list) or not isinstance(node_resources, list):
        return None
    return node_resources + resources


def canonical_inventory(payload, inventory, proxmox_resources=None, backup_state_file=None):
    """Build the active inventory shared by Systems and Target Preview."""
    if proxmox_resources is None:
        return active_inventory_projection(payload, inventory)

    status_by_id = {
        str(item.get("id")): item for item in payload.get("targets", [])
        if isinstance(item, dict)
    }
    targets = []

    def merge(base, status):
        merged = dict(base)
        if isinstance(status, dict):
            merged.update(status)
        for key in ("id", "type", "name", "node"):
            if base.get(key) is not None:
                merged[key] = base[key]
        # The inventory only knows the default transport for Proxmox guests
        # (QGA).  A completed check record is authoritative for the transport
        # actually used, for example SSH for an explicitly configured
        # pfSense/FreeBSD VM.
        if not merged.get("transport"):
            merged["transport"] = base.get("transport")
        return merged

    nodes = {
        str(item.get("node")): item for item in proxmox_resources
        if isinstance(item, dict) and item.get("type") == "node" and item.get("node")
    }
    for node, resource in nodes.items():
        status = status_by_id.get(f"host:{node}")
        cluster_online = resource.get("status") == "online"
        base = {"id": f"host:{node}", "type": "host", "transport": "local",
                "name": node, "node": node,
                "reachable": cluster_online,
                "check_status": "ok" if cluster_online else "offline"}
        merged = merge(base, status)
        # Cluster membership is the authoritative current reachability signal
        # for Proxmox nodes.  A stale check record must not turn an online
        # cluster member into an Offline badge.  Preserve a real check error,
        # but represent an old offline observation without an error as unknown.
        merged["reachable"] = cluster_online
        if cluster_online and merged.get("check_status") == "offline":
            merged["check_status"] = "error" if merged.get("error") else "unknown"
        elif not cluster_online:
            merged["check_status"] = "offline"
        targets.append(merged)

    for resource in proxmox_resources:
        kind = resource.get("type")
        if kind not in {"lxc", "qemu"} or resource.get("template"):
            continue
        target_id = str(resource.get("vmid", ""))
        node = str(resource.get("node", ""))
        if not target_id or not node:
            continue
        status = status_by_id.get(target_id)
        node_status = nodes.get(node, {}).get("status")
        base = {"id": target_id, "type": "lxc" if kind == "lxc" else "vm",
                "transport": "pct" if kind == "lxc" else "qga",
                "name": resource.get("name") or target_id, "node": node,
                "status": resource.get("status"),
                "reachable": False if node_status == "offline" else None,
                "check_status": "offline" if node_status == "offline" else "unknown"}
        targets.append(merge(base, status))

    active_external_ids = {item["id"] for item in inventory if item.get("transport") == "ssh"}
    for target_id in active_external_ids:
        status = status_by_id.get(target_id)
        inventory_item = next(item for item in inventory if item["id"] == target_id)
        base = {"id": target_id, "type": "external", "transport": "ssh",
                "name": target_id, "reachable": None, "check_status": "unknown",
                "os": None, "updater": None, "updates": {"available": None},
                "reboot_required": None, "last_check": None, "error": None, "node": None,
                "backup_status": external_backup_status(backup_state_file, target_id)
                if backup_state_file else None}
        targets.append(merge(base, status))

    projected = dict(payload)
    projected["targets"] = targets
    return projected


def resolve_filter_ids(only, exclude, tag_filter, eligible_ids=None, scope="update"):
    """Resolve the existing Proxmox tag filter without contacting targets."""
    if not tag_filter.is_file():
        raise ValueError("The tag filter is unavailable.")
    script = (
        'source "$1"\n'
        'apply_only_exclude_tags ONLY EXCLUDE\n'
        'printf "%s\\n%s\\n" "$ONLY" "$EXCLUDE"\n'
    )
    environment = os.environ.copy()
    environment["ONLY"] = only
    environment["EXCLUDE"] = exclude
    environment["UU_FILTER_SCOPE"] = scope
    if eligible_ids is not None:
        environment["UU_FILTER_ELIGIBLE_IDS"] = " ".join(sorted(eligible_ids))
    result = subprocess.run(
        ["bash", "-c", script, "ultimate-updater-filter", str(tag_filter)],
        capture_output=True, text=True, timeout=10, env=environment, check=False,
    )
    if result.returncode:
        raise ValueError("The tag filter could not be evaluated.")
    lines = result.stdout.splitlines()
    return (lines[0].split() if lines else [], lines[1].split() if len(lines) > 1 else [])


def filter_tokens(value):
    return [token for token in re.split(r"[\s,;|]+", value.strip()) if token]


def preview_eligible_ids(targets, config, scope):
    """Mirror the runtime's type/state eligibility before tag filtering."""
    if scope == "check":
        enabled = {
            "lxc": config.get("CHECK_WITH_LXC", "true"),
            "vm": config.get("CHECK_WITH_VM", "true"),
        }
        states = {
            "lxc": {"running": config.get("CHECK_RUNNING_CONTAINER", "true"),
                    "stopped": config.get("CHECK_STOPPED_CONTAINER", "true")},
            "vm": {"running": config.get("CHECK_RUNNING_VM", "true"),
                   "stopped": config.get("CHECK_STOPPED_VM", "true"),
                   "paused": config.get("CHECK_PAUSED_VM", "true")},
        }
    else:
        enabled = {
            "lxc": config.get("WITH_LXC", "true"),
            "vm": config.get("WITH_VM", "true"),
        }
        states = {
            "lxc": {"running": config.get("RUNNING_CONTAINER", "true"),
                    "stopped": config.get("STOPPED_CONTAINER", "true")},
            "vm": {"running": config.get("RUNNING_VM", "true"),
                   "stopped": config.get("STOPPED_VM", "true")},
        }
    eligible = set()
    for item in targets:
        kind = str(item.get("type", "")).lower()
        if kind not in {"lxc", "vm"} or not str(item.get("id", "")).isdigit():
            continue
        if str(enabled[kind]).lower() != "true":
            continue
        state = str(item.get("status", "")).lower()
        if state and state in states[kind] and str(states[kind][state]).lower() != "true":
            continue
        if state in states[kind] or not state:
            eligible.add(str(item["id"]))
    return eligible


def target_preview(payload, config, tag_filter, inventory, proxmox_resources=None,
                   filter_keys=("ONLY_UPDATE_CHECK", "EXCLUDE_UPDATE_CHECK")):
    projected = canonical_inventory(payload, inventory, proxmox_resources)
    targets = [dict(item) for item in projected["targets"]]
    known_ids = {str(item.get("id", "")) for item in targets}

    only_key, exclude_key = filter_keys
    only = str(config.get(only_key) or "")
    exclude = str(config.get(exclude_key) or "")
    eligible_ids = preview_eligible_ids(targets, config, "check" if filter_keys[0].startswith("ONLY_UPDATE") else "update")
    resolved_only, resolved_exclude = resolve_filter_ids(
        only, exclude, tag_filter, eligible_ids, "check" if filter_keys[0].startswith("ONLY_UPDATE") else "update",
    )
    selected_ids = set(resolved_only)
    excluded_ids = set(resolved_exclude)
    only_active = bool(selected_ids)
    external_ids = {str(item.get("id", "")).lower() for item in inventory
                    if item.get("transport") == "ssh"}
    only_external_ids = {token.lower() for token in filter_tokens(only)} & external_ids
    excluded_external_ids = {token.lower() for token in filter_tokens(exclude)} & external_ids
    filterable = lambda item: (
        str(item.get("type", "")).lower() in {"lxc", "vm"}
        and str(item.get("id", "")).isdigit()
    ) or str(item.get("type", "")).lower() == "external"
    def selected(item):
        item_id = str(item.get("id", ""))
        if str(item.get("type", "")).lower() in {"lxc", "vm"}:
            return ((not only_active) or item_id in selected_ids) and item_id not in excluded_ids
        item_id = item_id.lower()
        return ((not only_active) or item_id in only_external_ids) and item_id not in excluded_external_ids
    if only_active:
        included = [item for item in targets if not filterable(item) or selected(item)]
        excluded = [item for item in targets if filterable(item) and not selected(item)]
        mode = "only"
    elif exclude:
        included = [item for item in targets if not filterable(item) or selected(item)]
        excluded = [item for item in targets if filterable(item) and not selected(item)]
        mode = "exclude"
    else:
        included, excluded, mode = targets, [], "none"

    def public_item(item):
        kind = str(item.get("type", "")).lower()
        label = item.get("name") if kind not in {"host", "external"} else item.get("name") or str(item.get("id", "")).removeprefix("host:")
        if kind in {"lxc", "vm"} and item.get("name"):
            label = f"{item.get('id')} · {item.get('name')}"
        if item.get("reachable") is False:
            label = f"{label} · offline"
        return {"label": label or str(item.get("id", "")), "type": kind}

    raw_tokens = [(token, True) for token in filter_tokens(only)] + [(token, False) for token in filter_tokens(exclude)]
    def token_has_match(token, eligible_scope):
        if token.lower() in external_ids:
            return True
        if token.isdigit():
            return token in (eligible_scope if eligible_scope is not None else known_ids)
        token_only, _ = resolve_filter_ids(
            token, "", tag_filter, eligible_scope,
            "check" if filter_keys[0].startswith("ONLY_UPDATE") else "update",
        )
        return bool(token_only)

    only_unknown = [token for token, from_only in raw_tokens
                    if from_only and not token_has_match(token, eligible_ids)]
    exclude_unknown = [token for token, from_only in raw_tokens
                       if not from_only and not token_has_match(token, None)]
    return {
        "mode": mode,
        "only_configured": only,
        "only_matches": len(selected_ids),
        "only_active": only_active,
        "effective_selection": "only-matches" if only_active else "all-eligible",
        "included": [public_item(item) for item in included],
        "excluded": [public_item(item) for item in excluded],
        "unknown": only_unknown + exclude_unknown,
        "only_unknown": only_unknown,
        "exclude_unknown": exclude_unknown,
        "inventory_available": bool(targets),
        "generated_at": projected.get("generated_at"),
    }


def validate_inventory_text(content, script):
    if not script.is_file():
        raise ValueError("Target inventory validator is not installed.")
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(content)
        candidate = Path(handle.name)
    try:
        result = subprocess.run(["bash", str(script), str(candidate)], capture_output=True,
                                text=True, timeout=15, check=False)
    finally:
        candidate.unlink(missing_ok=True)
    if result.returncode:
        message = (result.stderr or result.stdout).strip()
        raise ValueError(message or "Target inventory is invalid.")


def validate_target_payload(payload, current_id=None):
    if not isinstance(payload, dict):
        raise ValueError("Target data must be an object.")
    target_id = payload.get("id", current_id)
    host = payload.get("host")
    user = payload.get("user", "root")
    port = payload.get("port", 22)
    if not isinstance(target_id, str) or not TARGET_RE.fullmatch(target_id):
        raise ValueError("Target name is invalid.")
    if current_id is not None and target_id != current_id:
        raise ValueError("Target names cannot be changed; remove and add a new target.")
    if not isinstance(host, str) or not HOST_RE.fullmatch(host):
        raise ValueError("Host or IP is invalid.")
    if not isinstance(user, str) or not USER_RE.fullmatch(user):
        raise ValueError("SSH user is invalid.")
    if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("SSH port must be between 1 and 65535.")
    return {"id": target_id, "host": host, "user": user, "port": port, "transport": "ssh"}


def update_inventory_text(content, target, current_id=None, delete=False):
    headers = list(re.finditer(r"(?m)^\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?(?:\r?\n|$)", content))
    wanted_id = current_id or target["id"]
    index = next((i for i, match in enumerate(headers) if match.group(1) == wanted_id), None)
    if index is None and not delete:
        if content and not content.endswith("\n"):
            content += "\n"
        content += (f"\n[{target['id']}]\n" if content else f"[{target['id']}]\n")
        content += f"host={target['host']}\ntransport=ssh\nuser={target['user']}\nport={target['port']}\n"
        return content
    if index is None:
        raise KeyError("target not found")
    start = headers[index].start()
    end = headers[index + 1].start() if index + 1 < len(headers) else len(content)
    section_text = content[start:end]
    if delete:
        return content[:start] + content[end:]
    replacements = {"host": target["host"], "transport": "ssh", "user": target["user"], "port": str(target["port"])}
    found = set()
    new_lines = []
    for line in section_text.splitlines(keepends=True):
        match = re.match(r"^(\s*)(host|port|transport|user)(\s*=\s*)([^#\r\n]*?)(\s*(?:#.*)?)?(\r?\n)?$", line)
        if match and match.group(2) in replacements:
            key = match.group(2); found.add(key)
            new_lines.append(f"{match.group(1)}{key}{match.group(3)}{replacements[key]}{match.group(5) or ''}{match.group(6) or ''}")
        else:
            new_lines.append(line)
    if new_lines and not new_lines[-1].endswith("\n"):
        new_lines[-1] += "\n"
    new_lines.extend(f"{key}={replacements[key]}\n" for key in replacements if key not in found)
    return content[:start] + "".join(new_lines) + content[end:]


def locked_atomic_update(path, updater):
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = Path(str(path) + ".uu-lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        content = path.read_text(encoding="utf-8") if path.exists() else ""
        updated = updater(content)
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o640
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as temp:
            temp.write(updated)
            temp.flush()
            os.fsync(temp.fileno())
            temporary = Path(temp.name)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)


class AuthStore:
    SESSION_SECONDS = 8 * 60 * 60

    def __init__(self, path):
        self.path = path
        self.sessions = {}
        self.failed_logins = {}
        self.backend = os.environ.get("UU_AUTH_BACKEND", "pam").strip().lower()

    @property
    def configured(self):
        if self.backend == "pam":
            return pam_authenticate is not None and Path("/etc/pam.d/login").is_file()
        if self.backend != "internal":
            return False
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return isinstance(data, dict) and bool(data.get("username")) and bool(data.get("password_hash"))
        except (OSError, ValueError, TypeError):
            return False

    def verify(self, username, password):
        if self.backend == "pam":
            return username == "root" and pam_authenticate is not None and pam_authenticate(username, password)
        if self.backend != "internal":
            return False
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if not hmac.compare_digest(str(data.get("username", "")), username):
                return False
            salt = base64.b64decode(data["salt"])
            expected = base64.b64decode(data["password_hash"])
            actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt,
                                         int(data.get("iterations", 210000)))
            return hmac.compare_digest(actual, expected)
        except (OSError, ValueError, TypeError, KeyError):
            return False

    def login(self, username, password, client):
        now = time.time()
        attempts, window = self.failed_logins.get(client, (0, now))
        if now - window >= 60:
            attempts, window = 0, now
        if attempts >= 5:
            return None
        if not self.verify(username, password):
            self.failed_logins[client] = (attempts + 1, window)
            return None
        self.failed_logins.pop(client, None)
        token = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(32)
        self.sessions[token] = {"user": username, "csrf": csrf, "expires": time.time() + self.SESSION_SECONDS}
        return token, csrf

    def session(self, token):
        item = self.sessions.get(token)
        if not item:
            return None
        if item["expires"] <= time.time():
            self.sessions.pop(token, None)
            return None
        item["expires"] = time.time() + self.SESSION_SECONDS
        return item

    def logout(self, token):
        self.sessions.pop(token, None)


class StatusHandler(BaseHTTPRequestHandler):
    server_version = "UltimateUpdaterUI/1"

    def current_session(self):
        cookie = self.headers.get("Cookie", "")
        token = next((part.strip().split("=", 1)[1] for part in cookie.split(";")
                      if part.strip().startswith("UU_SESSION=")), "")
        return self.server.auth.session(token) if token else None

    def auth_error(self, message="Authentication required.", status=HTTPStatus.UNAUTHORIZED):
        self.send_json(error_payload("AUTH_REQUIRED", message), status)
        return False

    def authenticated(self):
        if not self.server.auth.configured:
            return self.auth_error("Web authentication is not configured.", HTTPStatus.SERVICE_UNAVAILABLE)
        return bool(self.current_session()) or self.auth_error()

    def same_origin(self):
        origin = self.headers.get("Origin")
        if not origin:
            return True
        host = self.headers.get("Host", "")
        return origin in {f"http://{host}", f"https://{host}"}

    def write_allowed(self):
        session = self.current_session()
        if not session:
            return self.auth_error()
        if not self.same_origin():
            self.send_json(error_payload("ORIGIN_REJECTED", "The request origin is not allowed."), HTTPStatus.FORBIDDEN)
            return False
        if not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), session["csrf"]):
            self.send_json(error_payload("CSRF_REJECTED", "A valid CSRF token is required."), HTTPStatus.FORBIDDEN)
            return False
        return True

    def send_bytes(self, body, content_type, status=HTTPStatus.OK):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_attachment(self, body, filename, content_type="text/plain; charset=utf-8"):
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload, status=HTTPStatus.OK):
        self.send_bytes(json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8", status)

    def send_json_with_cookie(self, payload, cookie, status=HTTPStatus.OK):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("invalid content length")
        if length > 4096:
            raise OverflowError("request body is too large")
        if length and not self.headers.get("Content-Type", "").split(";", 1)[0].lower() == "application/json":
            raise ValueError("JSON content type is required")
        if not length:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ValueError("JSON body is invalid") from error
        return payload

    def run_command(self, args, timeout=300, extra_env=None, encoding=None):
        environment = {**os.environ, "UU_JOB_STATE_DIR": str(self.server.jobs_dir)}
        if extra_env:
            environment.update(extra_env)
        options = {
            "stdin": subprocess.DEVNULL,
            "capture_output": True,
            "text": True,
            "timeout": timeout,
            "check": False,
            "env": environment,
        }
        if encoding:
            options.update(encoding=encoding, errors="replace")
        return subprocess.run(args, **options)

    def jobs(self):
        runner = self.server.job_runner
        if not runner.is_file() or not runner.stat().st_mode & 0o111:
            raise RuntimeError("job runner is not available")
        result = self.run_command([str(runner), "list"], timeout=15)
        if result.returncode:
            raise RuntimeError("job state could not be read")
        rows = [parse_state_line(line) for line in result.stdout.splitlines()]
        rows = [row for row in rows if row and JOB_RE.fullmatch(row["unit"])]
        # Keep the API response bounded. Running jobs are always retained; the
        # remaining slots contain the newest terminal jobs by metadata time.
        def sort_key(row):
            value = row.get("started_at") or ""
            return value
        rows.sort(key=sort_key, reverse=True)
        running = [row for row in rows if row.get("state") in {"running", "pending", "starting"}]
        finished = [row for row in rows if row.get("state") not in {"running", "pending", "starting"}]
        selected = running + finished[:max(0, VISIBLE_JOB_LIMIT - len(running))]
        selected.sort(key=sort_key, reverse=True)
        return selected

    def updater_version(self, force=False):
        now = time.monotonic()
        cached = getattr(self.server, "version_cache", None)
        if not force and cached and now - cached["at"] < 300:
            return cached["data"]
        try:
            if not self.server.update_script.is_file() or not self.server.update_script.stat().st_mode & 0o111:
                raise OSError("update script is unavailable")
            result = self.run_command(
                [str(self.server.update_script), "status"], timeout=45,
                extra_env={"TERM": "dumb", "UU_NONINTERACTIVE": "true"},
            )
            data = parse_updater_version_output(f"{result.stdout}\n{result.stderr}")
        except (OSError, subprocess.TimeoutExpired):
            data = {"state": "unavailable", "branch": None, "installed": None,
                    "available": None, "commit": "unknown", "available_commit": "unknown",
                    "tag": None, "update_available": False, "components": []}
        data["checked_at"] = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        # Do not retain transient network/rate-limit failures for the normal
        # success-cache TTL. The UI performs one deliberately delayed retry.
        self.server.version_cache = {"at": now, "data": data} if data.get("state") == "ok" else None
        return data

    def valid_target(self, target):
        return bool(TARGET_RE.fullmatch(target))

    def valid_job(self, unit):
        if not JOB_RE.fullmatch(unit):
            return False
        return any(row["unit"] == unit for row in self.jobs())

    def job_record(self, unit):
        if not JOB_RE.fullmatch(unit):
            return None
        return next((row for row in self.jobs() if row["unit"] == unit), None)

    def config_content(self):
        return self.server.config_file.read_text(encoding="utf-8") if self.server.config_file.exists() else ""

    def inventory_content(self):
        return self.server.inventory_file.read_text(encoding="utf-8") if self.server.inventory_file.exists() else ""

    def inventory_data(self):
        content = self.inventory_content()
        validate_inventory_text(content, self.server.inventory_script)
        return [item for item in inventory_payload(content) if item["transport"] == "ssh"]

    def internal_ssh_values(self):
        if not self.server.internal_ssh_file.exists():
            return {}
        return parse_internal_ssh_text(self.server.internal_ssh_file.read_text(encoding="utf-8"))

    def internal_ssh_catalog(self):
        overrides = self.internal_ssh_values()
        resources = proxmox_inventory_snapshot() or []
        nodes = [str(item.get("node")) for item in resources
                 if isinstance(item, dict) and item.get("type") == "node" and item.get("node")]
        local_node = subprocess.run(["hostname", "-s"], capture_output=True, text=True,
                                    timeout=3, check=False).stdout.strip()
        corosync = Path("/etc/pve/corosync.conf")
        node_hosts = {}
        if corosync.exists():
            text = corosync.read_text(encoding="utf-8", errors="replace")
            for block in re.findall(r"node\s*\{(.*?)\}", text, re.S):
                name = re.search(r"\bname\s*:\s*([^\s}]+)", block)
                addr = re.search(r"\bring0_addr\s*:\s*([^\s}]+)", block)
                if name and addr:
                    node_hosts[name.group(1)] = addr.group(1)
        result = []
        available = []
        for node in sorted(set(nodes)):
            section = f"node:{node}"
            override = overrides.get(section, {})
            result.append({"kind": "node", "id": node, "name": node,
                           "local": node == local_node,
                           "host": override.get("host", node_hosts.get(node, node)),
                           "user": override.get("user", "root"),
                           "port": int(override.get("port", "22")),
                           "identity_file": override.get("identity_file", ""),
                           "enabled": override.get("enabled", "true") == "true",
                           "source": "Internal SSH override" if override else "Cluster/default",
                           "override": bool(override), "has_legacy_profile": False})
        vm_profiles = self.server.config_file.parent / "VMs"
        vm_ids = {str(item.get("vmid", item.get("id", ""))).split("/")[-1]: item
                  for item in resources if isinstance(item, dict) and item.get("type") in {"qemu", "lxc"}}
        for vmid in sorted(vm_ids, key=lambda value: (not value.isdigit(), value)):
            kind = "lxc" if vm_ids[vmid].get("type") == "lxc" else "vm"
            section = f"{kind}:{vmid}"; override = overrides.get(section, {})
            defaults = {}
            profile = vm_profiles / vmid
            if profile.is_file():
                for line in profile.read_text(encoding="utf-8", errors="replace").splitlines():
                    if "=" in line:
                        key, value = line.split("=", 1); defaults[key.strip()] = value.strip().strip('"')
            host = override.get("host", defaults.get("IP", ""))
            user = override.get("user", defaults.get("USER", "root"))
            port = override.get("port", defaults.get("SSH_VM_PORT", "22"))
            target = {"kind": kind, "id": vmid, "name": vm_ids[vmid].get("name", vmid),
                      "node": vm_ids[vmid].get("node"), "host": host, "user": user,
                      "port": int(port) if str(port).isdigit() else 22,
                      "identity_file": override.get("identity_file", ""),
                      "enabled": override.get("enabled", "true") == "true",
                      "source": "Internal SSH override" if override else ("Existing SSH profile (legacy format)" if defaults else "QGA/default"),
                      "override": bool(override), "has_legacy_profile": profile.is_file()}
            if override or defaults:
                result.append(target)
            else:
                target["unconfigured"] = True
                available.append(target)
        return result, available

    def internal_ssh_targets(self):
        return self.internal_ssh_catalog()[0]

    def internal_ssh_available_targets(self):
        return self.internal_ssh_catalog()[1]

    def handle_internal_ssh_get(self):
        self.send_json({"path": str(self.server.internal_ssh_file),
                        "source_of_truth": "local internal SSH override; defaults remain automatic",
                        "targets": self.internal_ssh_targets(),
                        "available": self.internal_ssh_available_targets()})

    def internal_ssh_section(self, kind, target_id):
        if kind not in {"node", "vm", "lxc"} or not INTERNAL_ID_RE.fullmatch(target_id):
            raise ValueError("Invalid internal SSH target.")
        target = next((item for item in self.internal_ssh_targets()
                       if item["kind"] == kind and item["id"] == target_id), None)
        if not target:
            target = next((item for item in self.internal_ssh_available_targets()
                           if item["kind"] == kind and item["id"] == target_id), None)
        if not target:
            raise KeyError("Internal SSH target not found.")
        return f"{kind}:{target_id}", target

    def handle_internal_ssh_update(self, kind, target_id, payload):
        section, _ = self.internal_ssh_section(kind, target_id)
        if not isinstance(payload, dict):
            raise ValueError("Internal SSH settings are invalid.")
        allowed = {"host", "user", "port", "identity_file", "enabled"}
        values = payload.get("values")
        if not isinstance(values, dict) or set(values) - allowed:
            raise ValueError("Unsupported internal SSH setting.")
        clean = {}
        for key, value in values.items():
            if key == "host" and (not isinstance(value, str) or not HOST_RE.fullmatch(value)):
                raise ValueError("Host or IP is invalid.")
            if key == "user" and (not isinstance(value, str) or not USER_RE.fullmatch(value)):
                raise ValueError("SSH user is invalid.")
            if key == "port" and (isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 65535):
                raise ValueError("SSH port must be between 1 and 65535.")
            if key == "identity_file":
                if not isinstance(value, str) or not value.startswith("/") or not Path(value).is_file():
                    raise ValueError("Identity file must be an existing absolute path.")
            if key == "enabled" and not isinstance(value, bool):
                raise ValueError("Enabled must be boolean.")
            clean[key] = str(value).lower() if isinstance(value, bool) else str(value)
        def update(_content):
            data = parse_internal_ssh_text(_content) if _content.strip() else {}
            data[section] = clean
            return internal_ssh_text(data)
        locked_atomic_update(self.server.internal_ssh_file, update)
        self.send_json({"message": "Internal SSH override saved.", "target": target_id})

    def handle_internal_ssh_delete(self, kind, target_id):
        section, _ = self.internal_ssh_section(kind, target_id)
        def update(_content):
            data = parse_internal_ssh_text(_content) if _content.strip() else {}
            data.pop(section, None)
            return internal_ssh_text(data)
        locked_atomic_update(self.server.internal_ssh_file, update)
        self.send_json({"message": "Internal SSH override removed; automatic/default resolution restored.", "target": target_id})

    def handle_internal_ssh_test(self, kind, target_id):
        _, target = self.internal_ssh_section(kind, target_id)
        if target.get("local"):
            self.send_json({"message": "Local node does not require an SSH test."})
            return
        if not target.get("host"):
            self.send_json(error_payload("SSH_NOT_CONFIGURED", "No SSH configuration is available for this target."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        args = ["ssh", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if target.get("identity_file"):
            args += ["-o", "IdentitiesOnly=yes", "-i", target["identity_file"]]
        args += ["-p", str(target["port"]), f"{target['user']}@{target['host']}", "true"]
        try:
            result = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    timeout=8, check=False)
        except subprocess.TimeoutExpired:
            self.send_json(error_payload("SSH_TEST_FAILED", "Connection timed out."), HTTPStatus.BAD_GATEWAY)
            return
        except OSError:
            self.send_json(error_payload("SSH_TEST_FAILED", "Connection test could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        if result.returncode:
            error_text = result.stderr.upper()
            message = "Connection failed."
            if "REMOTE HOST IDENTIFICATION HAS CHANGED" in error_text or "HOST KEY" in error_text:
                message = "Host key verification failed."
            elif "PERMISSION DENIED" in error_text or "AUTHENTICATION" in error_text:
                message = "Authentication failed."
            elif "CONNECTION REFUSED" in error_text:
                message = "Connection refused."
            elif "TIMED OUT" in error_text or "TIMEOUT" in error_text:
                message = "Connection timed out."
            elif "NO ROUTE TO HOST" in error_text or "NETWORK IS UNREACHABLE" in error_text or "COULD NOT RESOLVE HOST" in error_text:
                message = "Host unreachable."
            self.send_json(error_payload("SSH_TEST_FAILED", message), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"message": "Connection successful."})

    def external_target_known(self, target):
        return any(item["id"] == target for item in self.inventory_data())

    def handle_external_settings_get(self, target):
        if not self.valid_target(target) or not self.external_target_known(target):
            self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
            return
        try:
            result = self.run_command([str(self.server.cli), "external", "settings-get", target], timeout=135)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("EXTERNAL_SETTINGS_UNAVAILABLE", "External settings are unavailable."), HTTPStatus.BAD_GATEWAY)
            return
        if result.returncode:
            code = "EXTERNAL_SETTINGS_INVALID" if result.returncode == 11 else "EXTERNAL_SETTINGS_UNAVAILABLE"
            status = HTTPStatus.UNPROCESSABLE_ENTITY if result.returncode == 11 else HTTPStatus.BAD_GATEWAY
            self.send_json(error_payload(code, "External settings are invalid." if result.returncode == 11 else "External settings unavailable; target may be offline."), status)
            return
        try:
            values = parse_external_config_text(result.stdout)
        except ValueError:
            self.send_json(error_payload("EXTERNAL_SETTINGS_INVALID", "External settings are invalid."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"target": target, "source": "external-local", "values": values})

    def handle_external_settings_update(self, target, payload):
        if not self.valid_target(target) or not self.external_target_known(target):
            self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
            return
        values = payload.get("values") if isinstance(payload, dict) else None
        if not isinstance(values, dict) or set(values) != set(EXTERNAL_SETTING_KEYS):
            self.send_json(error_payload("INVALID_EXTERNAL_SETTINGS", "All External filter settings are required."), HTTPStatus.BAD_REQUEST)
            return
        for key in EXTERNAL_SETTING_KEYS:
            value = values[key]
            if not isinstance(value, str) or "\n" in value or "\r" in value or len(value) > 512:
                self.send_json(error_payload("INVALID_EXTERNAL_SETTINGS", "External filter values must be short single-line text."), HTTPStatus.BAD_REQUEST)
                return
        args = [str(self.server.cli), "external", "settings-set", target]
        args.extend(f"{key}={values[key]}" for key in EXTERNAL_SETTING_KEYS)
        try:
            result = self.run_command(args, timeout=135)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("EXTERNAL_SETTINGS_SAVE_FAILED", "External settings could not be saved."), HTTPStatus.BAD_GATEWAY)
            return
        if result.returncode:
            self.send_json(error_payload("EXTERNAL_SETTINGS_SAVE_FAILED", "External settings could not be saved; target may be offline or the write was denied."), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"target": target, "source": "external-local", "message": "External settings saved."})

    def handle_config_update(self, payload):
        normalized = validate_config_values(payload.get("values") if isinstance(payload, dict) else None)
        locked_atomic_update(self.server.config_file,
                             lambda content: update_config_text(content, normalized))
        self.send_json({"message": "Configuration saved.", "config": config_value_map(self.config_content())})

    def handle_config_preview(self, query):
        if not self.server.status_file.exists():
            self.send_json({"available": False, "message": "Target preview unavailable until the initial inventory has completed."})
            return
        with self.server.status_file.open(encoding="utf-8") as source:
            payload = json.load(source)
        only = query.get("only", [None])[0]
        exclude = query.get("exclude", [None])[0]
        scope = query.get("scope", ["check"])[0]
        if scope not in {"check", "update"}:
            self.send_json(error_payload("INVALID_PREVIEW_SCOPE", "Unsupported preview scope."), HTTPStatus.BAD_REQUEST)
            return
        filter_keys = ("ONLY", "EXCLUDE") if scope == "update" else ("ONLY_UPDATE_CHECK", "EXCLUDE_UPDATE_CHECK")
        config = config_value_map(self.config_content())
        if only is not None:
            config[filter_keys[0]] = only
        if exclude is not None:
            config[filter_keys[1]] = exclude
        inventory = self.inventory_data()
        preview = target_preview(
            payload, config, self.server.tag_filter_script, inventory,
            proxmox_inventory_snapshot(),
            filter_keys,
        )
        self.send_json({"available": True, "scope": scope, "preview": preview})

    def handle_target_add(self, payload):
        target = validate_target_payload(payload)
        content = self.inventory_content()
        validate_inventory_text(content, self.server.inventory_script)
        if any(item["id"] == target["id"] for item in inventory_payload(content)):
            self.send_json(error_payload("TARGET_EXISTS", "That external target already exists."), HTTPStatus.CONFLICT)
            return
        updated = update_inventory_text(content, target)
        validate_inventory_text(updated, self.server.inventory_script)
        locked_atomic_update(self.server.inventory_file, lambda _: updated)
        self.send_json({"message": "External target added.", "target": target}, HTTPStatus.CREATED)

    def handle_target_update(self, target_id, payload):
        current = validate_target_payload({"id": target_id, **(payload if isinstance(payload, dict) else {})}, target_id)
        content = self.inventory_content()
        validate_inventory_text(content, self.server.inventory_script)
        existing = next((item for item in inventory_payload(content) if item["id"] == target_id), None)
        if not existing:
            self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
            return
        if existing["transport"] != "ssh":
            raise ValueError("Only external SSH targets can be managed in the web UI.")
        updated = update_inventory_text(content, current, target_id)
        validate_inventory_text(updated, self.server.inventory_script)
        locked_atomic_update(self.server.inventory_file, lambda _: updated)
        self.send_json({"message": "External target saved.", "target": current})

    def handle_target_delete(self, target_id):
        content = self.inventory_content()
        validate_inventory_text(content, self.server.inventory_script)
        existing = next((item for item in inventory_payload(content) if item["id"] == target_id), None)
        if not existing:
            self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
            return
        if existing["transport"] != "ssh":
            raise ValueError("Only external SSH targets can be managed in the web UI.")
        updated = update_inventory_text(content, {"id": target_id}, target_id, delete=True)
        validate_inventory_text(updated, self.server.inventory_script)
        locked_atomic_update(self.server.inventory_file, lambda _: updated)
        self.send_json({"message": "External target removed.", "target": target_id})

    def handle_target_test(self, target_id):
        if not self.valid_target(target_id):
            self.send_json(error_payload("INVALID_TARGET", "The target name is invalid."), HTTPStatus.BAD_REQUEST)
            return
        try:
            if not any(item["id"] == target_id for item in self.inventory_data()):
                self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
                return
            result = self.run_command([str(self.server.external_script), "check", target_id], timeout=150)
            status = None
            if self.server.status_file.exists():
                payload = json.loads(self.server.status_file.read_text(encoding="utf-8"))
                status = next((item for item in payload.get("targets", []) if item.get("id") == target_id), None)
        except (OSError, ValueError, json.JSONDecodeError, subprocess.TimeoutExpired):
            self.send_json(error_payload("CONNECTION_TEST_FAILED", "The connection test failed."), HTTPStatus.BAD_GATEWAY)
            return
        if result.returncode or not status:
            message = (status or {}).get("error", {}).get("message") if status else "The target could not be checked."
            self.send_json(error_payload("CONNECTION_TEST_FAILED", message or "The target could not be checked."), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"message": "Connection test completed.", "target": status})

    def do_GET(self):  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path == "/":
            self.send_bytes(PAGE.encode(), "text/html; charset=utf-8")
            return
        if path in UI_ASSETS:
            filename, content_type = UI_ASSETS[path]
            try:
                self.send_bytes((self.server.asset_dir / filename).read_bytes(), content_type)
            except (OSError, UnicodeError):
                self.send_json(error_payload("ASSET_NOT_FOUND", "The requested UI asset is unavailable."), HTTPStatus.NOT_FOUND)
            return
        if path == "/api/session":
            session = self.current_session()
            if not self.server.auth.configured:
                self.send_json(error_payload("AUTH_NOT_CONFIGURED", "Run the local web-auth setup before using the UI."), HTTPStatus.SERVICE_UNAVAILABLE)
            elif not session:
                self.send_json(error_payload("AUTH_REQUIRED", "Authentication required."), HTTPStatus.UNAUTHORIZED)
            else:
                self.send_json({"authenticated": True, "username": session["user"], "csrf": session["csrf"]})
            return
        if not self.authenticated():
            return
        if path == "/api/config":
            try:
                self.send_json({"config": config_value_map(self.config_content()), "editable": sorted(CONFIG_KEYS)})
            except (OSError, UnicodeError):
                self.send_json(error_payload("CONFIG_UNAVAILABLE", "Configuration is unavailable."), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/config-preview":
            try:
                self.handle_config_preview(parse_qs(urlsplit(self.path).query, keep_blank_values=True))
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("CONFIG_PREVIEW_UNAVAILABLE", "Target preview is currently unavailable."), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/targets":
            try:
                self.send_json({"targets": self.inventory_data()})
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("TARGETS_INVALID", "External target inventory is invalid or unavailable."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if path == "/api/internal-ssh":
            try:
                self.handle_internal_ssh_get()
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("INTERNAL_SSH_UNAVAILABLE", "Internal SSH configuration is invalid or unavailable."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if len([part for part in path.split("/") if part]) == 5 and path.startswith("/api/internal-ssh/") and path.endswith("/test"):
            parts = [unquote(part) for part in path.split("/") if part]
            try:
                self.handle_internal_ssh_test(parts[2], parts[3])
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                self.send_json(error_payload("SSH_TEST_FAILED", "The connection test could not be completed."), HTTPStatus.BAD_GATEWAY)
            return
        if len([part for part in path.split("/") if part]) == 3 and path.startswith("/api/external-settings/"):
            target_id = unquote(path.rsplit("/", 1)[-1])
            try:
                self.handle_external_settings_get(target_id)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("EXTERNAL_SETTINGS_UNAVAILABLE", "External settings are unavailable."), HTTPStatus.BAD_GATEWAY)
            return
        if len([part for part in path.split("/") if part]) == 3 and path.startswith("/api/external-backup/"):
            target_id = unquote(path.rsplit("/", 1)[-1])
            try:
                if not any(item["id"] == target_id for item in self.inventory_data()):
                    self.send_json(error_payload("TARGET_NOT_FOUND", "That external target does not exist."), HTTPStatus.NOT_FOUND)
                    return
                self.send_json(external_backup_status(self.server.backup_state_file, target_id))
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("BACKUP_STATUS_UNAVAILABLE", "Backup verification status is unavailable."), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/status":
            try:
                # Remote VM updates finish their guest-side capture on the
                # owning node.  Refresh the central import before reading the
                # status file so a completed remote job cannot leave the UI
                # showing pre-update values while its ref remains pending.
                try:
                    self.jobs()
                except (OSError, RuntimeError, subprocess.TimeoutExpired):
                    # Status remains readable if the best-effort job refresh
                    # is temporarily unavailable; the next request retries.
                    pass
                with self.server.status_file.open(encoding="utf-8") as source:
                    payload = json.load(source)
                if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
                    raise ValueError
                inventory = self.inventory_data()
                payload = canonical_inventory(
                    payload, inventory, proxmox_inventory_snapshot(), self.server.backup_state_file,
                )
            except FileNotFoundError:
                self.send_json(error_payload("STATUS_NOT_FOUND", "No status file is available yet."), HTTPStatus.NOT_FOUND)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                self.send_json(error_payload("STATUS_INVALID", "The status file is missing or invalid."), HTTPStatus.UNPROCESSABLE_ENTITY)
            else:
                self.send_json(payload)
            return
        if path == "/api/jobs":
            try:
                self.send_json({"jobs": self.jobs()})
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                self.send_json(error_payload("JOBS_UNAVAILABLE", "Update job state is unavailable."), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/updater-version":
            try:
                force = parse_qs(urlsplit(self.path).query).get("force", ["0"])[0] == "1"
                self.send_json(self.updater_version(force=force))
            except (OSError, RuntimeError, subprocess.TimeoutExpired):
                self.send_json({"state": "unavailable", "branch": None, "installed": None,
                                "available": None, "commit": "unknown", "available_commit": "unknown",
                                "tag": None, "update_available": False, "components": []})
            return
        parts = [unquote(part) for part in path.split("/") if part]
        if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "log":
            unit = parts[2]
            try:
                job = self.job_record(unit)
                if not job:
                    raise ValueError
                if job.get("remote"):
                    result = self.run_command([str(self.server.job_runner), "remote-log", unit], timeout=15, encoding="utf-8")
                else:
                    result = self.run_command(["journalctl", "-u", unit, "-n", "200", "--no-pager", "-o", "cat"], timeout=15, encoding="utf-8")
                if result.returncode:
                    raise RuntimeError
                self.send_json({"unit": unit, "log": strip_ansi(result.stdout)})
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("JOB_LOG_UNAVAILABLE", "The requested job log is not available."), HTTPStatus.NOT_FOUND)
            return
        if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "download":
            unit = parts[2]
            try:
                if not JOB_RE.fullmatch(unit):
                    raise ValueError
                job = self.job_record(unit)
                if not job:
                    raise ValueError
                if job.get("remote"):
                    result = self.run_command([str(self.server.job_runner), "remote-log-full", unit], timeout=60, encoding="utf-8")
                else:
                    result = self.run_command(["journalctl", "-u", unit, "--no-pager", "-o", "cat"], timeout=60, encoding="utf-8")
                if result.returncode or not result.stdout:
                    raise RuntimeError
                filename = f"ultimate-updater-{unit}.log"
                self.send_attachment(strip_ansi(result.stdout).encode("utf-8"), filename)
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("JOB_LOG_UNAVAILABLE", "Full log is no longer available."), HTTPStatus.NOT_FOUND)
            return
        self.send_json(error_payload("NOT_FOUND", "Not found."), HTTPStatus.NOT_FOUND)

    def do_POST(self):  # noqa: N802 - stdlib handler API
        try:
            payload = self.read_body()
        except OverflowError as error:
            self.send_json(error_payload("REQUEST_TOO_LARGE", str(error)), HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return
        except ValueError as error:
            self.send_json(error_payload("BAD_REQUEST", str(error)), HTTPStatus.BAD_REQUEST)
            return
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if parts == ["api", "login"]:
            if not self.server.auth.configured:
                self.send_json(error_payload("AUTH_NOT_CONFIGURED", "Run the local web-auth setup before using the UI."), HTTPStatus.SERVICE_UNAVAILABLE)
                return
            username = payload.get("username") if isinstance(payload, dict) else None
            password = payload.get("password") if isinstance(payload, dict) else None
            if not isinstance(username, str) or not isinstance(password, str) or len(username) > 128 or len(password) > 1024:
                self.send_json(error_payload("LOGIN_FAILED", "Invalid credentials."), HTTPStatus.UNAUTHORIZED)
                return
            login = self.server.auth.login(username, password, self.client_address[0])
            if not login:
                self.send_json(error_payload("LOGIN_FAILED", "Invalid credentials."), HTTPStatus.UNAUTHORIZED)
                return
            token, csrf = login
            secure = "; Secure" if getattr(self.server, "tls_enabled", False) or self.headers.get("X-Forwarded-Proto", "").lower() == "https" else ""
            cookie = f"UU_SESSION={token}; Path=/; Max-Age={AuthStore.SESSION_SECONDS}; HttpOnly; SameSite=Lax{secure}"
            self.send_json_with_cookie({"authenticated": True, "username": username, "csrf": csrf}, cookie)
            return
        if parts == ["api", "logout"]:
            if not self.write_allowed():
                return
            cookie = self.headers.get("Cookie", "")
            token = next((part.strip().split("=", 1)[1] for part in cookie.split(";")
                          if part.strip().startswith("UU_SESSION=")), "")
            self.server.auth.logout(token)
            self.send_json_with_cookie({"authenticated": False}, "UU_SESSION=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax")
            return
        if not self.write_allowed():
            return
        if parts == ["api", "check-all"]:
            self.action_check_all()
            return
        if parts == ["api", "update-all"]:
            self.action_update_all()
            return
        if len(parts) == 3 and parts[:2] == ["api", "external-backup"]:
            target_id = parts[2]
            reference = payload.get("reference", "") if isinstance(payload, dict) else ""
            if not isinstance(reference, str):
                self.send_json(error_payload("INVALID_BACKUP_REFERENCE", "Backup reference must be text."), HTTPStatus.BAD_REQUEST)
                return
            try:
                result = self.run_command([str(self.server.cli), "external", "verify-backup", target_id, reference], timeout=15)
            except (OSError, subprocess.TimeoutExpired):
                self.send_json(error_payload("BACKUP_VERIFY_FAILED", "Backup verification could not be recorded."), HTTPStatus.BAD_GATEWAY)
                return
            if result.returncode:
                self.send_json(error_payload("BACKUP_VERIFY_FAILED", "Backup verification could not be recorded."), HTTPStatus.UNPROCESSABLE_ENTITY)
                return
            self.send_json({"message": "Backup verified for this external target.",
                            "status": external_backup_status(self.server.backup_state_file, target_id)})
            return
        if urlsplit(self.path).path == "/api/config":
            try:
                self.handle_config_update(payload)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("CONFIG_NOT_SAVED", "Configuration was rejected and not changed."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if len(parts) == 3 and parts[:2] == ["api", "external-settings"]:
            try:
                self.handle_external_settings_update(parts[2], payload)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("EXTERNAL_SETTINGS_SAVE_FAILED", "External settings could not be saved."), HTTPStatus.BAD_GATEWAY)
            return
        if len(parts) == 5 and parts[:2] == ["api", "internal-ssh"] and parts[4] == "test":
            try:
                self.handle_internal_ssh_test(parts[2], parts[3])
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                self.send_json(error_payload("SSH_TEST_FAILED", "The connection test could not be completed."), HTTPStatus.BAD_GATEWAY)
            return
        if len(parts) == 4 and parts[:2] == ["api", "internal-ssh"]:
            try:
                self.handle_internal_ssh_update(parts[2], parts[3], payload)
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                self.send_json(error_payload("INTERNAL_SSH_SAVE_FAILED", str(error) or "Internal SSH settings were rejected."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if parts == ["api", "targets"]:
            try:
                self.handle_target_add(payload)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("TARGET_NOT_SAVED", "External target was rejected and not changed."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if len(parts) == 4 and parts[:2] == ["api", "targets"] and parts[3] == "test":
            self.handle_target_test(parts[2])
            return
        if len(parts) == 3 and parts[:2] == ["api", "check"]:
            self.action_check(parts[2])
            return
        if len(parts) == 3 and parts[:2] == ["api", "update"]:
            self.action_update(parts[2], payload)
            return
        if len(parts) == 3 and parts[:2] == ["api", "check-node"]:
            self.action_check_node(parts[2])
            return
        if len(parts) == 3 and parts[:2] == ["api", "update-node"]:
            self.action_update_node(parts[2])
            return
        if parts == ["api", "updater-update"]:
            self.action_updater_update(payload)
            return
        self.send_json(error_payload("UNSUPPORTED_ACTION", "Unsupported API action."), HTTPStatus.METHOD_NOT_ALLOWED)

    def action_check(self, target):
        if not self.valid_target(target):
            self.send_json(error_payload("INVALID_TARGET", "The target name is invalid."), HTTPStatus.BAD_REQUEST)
            return
        try:
            result = self.run_command([str(self.server.job_runner), "start-check", target,
                                       str(self.server.cli), "target"], timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("CHECK_START_FAILED", "The check job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("JOB_ALREADY_RUNNING", "A job is already running for this target."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("CHECK_START_FAILED", "The check job could not be started."), HTTPStatus.CONFLICT if result.returncode == 3 else HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"target": target, "job": job_match.group(1), "type": "check",
                        "state": "running", "message": "Check job started."}, HTTPStatus.ACCEPTED)

    def action_update(self, target, payload=None):
        if not self.valid_target(target):
            self.send_json(error_payload("INVALID_TARGET", "The target name is invalid."), HTTPStatus.BAD_REQUEST)
            return
        allow_without_backup = isinstance(payload, dict) and payload.get("allow_without_backup") is True
        try:
            is_external = any(item["id"] == target and item["transport"] == "ssh"
                              for item in self.inventory_data())
        except (OSError, ValueError, subprocess.TimeoutExpired):
            self.send_json(error_payload("TARGETS_INVALID", "External target inventory is invalid or unavailable."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        command = [str(self.server.cli), "update", target]
        if is_external and allow_without_backup:
            command.append("--without-verified-backup")
        try:
            result = self.run_command(command, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("UPDATE_START_FAILED", "The update job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode != 0:
            if result.returncode == 41:
                self.send_json(error_payload(
                    "EXTERNAL_BACKUP_REQUIRED",
                    "No recent backup is verified for this external target.",
                ), HTTPStatus.CONFLICT)
                return
            code = "JOB_ALREADY_RUNNING" if result.returncode == 3 else "UPDATE_START_FAILED"
            message = "An update job is already running for this target." if result.returncode == 3 else "The update job could not be started."
            self.send_json(error_payload(code, message), HTTPStatus.CONFLICT if result.returncode == 3 else HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("INVALID_JOB_RESPONSE", "The updater returned no valid job ID."), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"target": target, "job": job_match.group(1), "state": "running", "message": "Update job started."}, HTTPStatus.ACCEPTED)

    def known_node(self, node):
        if not isinstance(node, str) or not HOST_RE.fullmatch(node):
            return False
        try:
            status = json.loads(self.server.status_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        return any(isinstance(item, dict) and item.get("type") == "host" and
                   str(item.get("id", "")).removeprefix("host:") == node
                   for item in status.get("targets", []))

    def action_check_all(self):
        try:
            result = self.run_command([str(self.server.job_runner), "start-check", "all-systems",
                                       str(self.server.cli), "all"], timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("CHECK_START_FAILED", "The full check could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("CHECK_ALREADY_RUNNING", "A full check is already running."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("CHECK_START_FAILED", "The full check could not be started."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"state": "running", "job": job_match.group(1), "type": "check", "target": "all-systems",
                        "message": "Full check job started."}, HTTPStatus.ACCEPTED)

    def action_update_all(self):
        try:
            result = self.run_command([str(self.server.cli), "update-all"], timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("UPDATE_START_FAILED", "The full update job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("JOB_ALREADY_RUNNING", "A full update is already running."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("UPDATE_START_FAILED", "The full update job could not be started."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"job": job_match.group(1), "target": "all-systems", "state": "running", "message": "Full update job started."}, HTTPStatus.ACCEPTED)

    def action_updater_update(self, payload):
        branch = payload.get("branch") if isinstance(payload, dict) else None
        if branch not in {"master", "beta", "develop"}:
            self.send_json(error_payload("INVALID_BRANCH", "The installed updater branch is unavailable."), HTTPStatus.BAD_REQUEST)
            return
        try:
            result = self.run_command([str(self.server.job_runner), "start-selfupdate",
                                       str(self.server.update_script), branch], timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("SELFUPDATE_START_FAILED", "The updater self-update job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("SELFUPDATE_ALREADY_RUNNING", "An updater self-update is already running."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("SELFUPDATE_START_FAILED", "The updater self-update job could not be started."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"job": job_match.group(1), "target": "selfupdate", "type": "selfupdate",
                        "state": "running", "message": "Updater self-update job started."}, HTTPStatus.ACCEPTED)

    def action_check_node(self, node):
        if not self.known_node(node):
            self.send_json(error_payload("INVALID_NODE", "The requested Proxmox node is not known."), HTTPStatus.NOT_FOUND)
            return
        try:
            result = self.run_command([str(self.server.job_runner), "start-check", node,
                                       str(self.server.cli), "node"], timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("CHECK_START_FAILED", "The node check job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("JOB_ALREADY_RUNNING", "A job is already running for this node."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("CHECK_START_FAILED", "The node check job could not be started."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json({"node": node, "job": job_match.group(1), "type": "check",
                        "state": "running", "message": "Node check job started."}, HTTPStatus.ACCEPTED)

    def action_update_node(self, node):
        if not self.known_node(node):
            self.send_json(error_payload("INVALID_NODE", "The requested Proxmox node is not known."), HTTPStatus.NOT_FOUND)
            return
        try:
            result = self.run_command([str(self.server.cli), "update-node", node], timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("UPDATE_START_FAILED", "The node update job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode == 3:
            self.send_json(error_payload("JOB_ALREADY_RUNNING", "An update job is already running for this node."), HTTPStatus.CONFLICT)
            return
        if result.returncode or not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            detail = (result.stderr or result.stdout or "").strip().replace("\n", " ")[:300]
            message = "The node update job could not be started."
            if detail:
                message += f" {detail}"
            self.send_json(error_payload("UPDATE_START_FAILED", message), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        job_unit = job_match.group(1)
        try:
            registered = self.job_record(job_unit)
        except RuntimeError:
            registered = None
        if not registered:
            self.send_json(error_payload(
                "UPDATE_NOT_REGISTERED",
                "The node update started remotely but was not registered in the central job list.",
            ), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"node": node, "job": job_unit, "state": "running", "message": "Node update job started."}, HTTPStatus.ACCEPTED)

    def do_PUT(self):  # noqa: N802
        if not self.write_allowed():
            return
        try:
            payload = self.read_body()
        except (OverflowError, ValueError) as error:
            self.send_json(error_payload("BAD_REQUEST", str(error)), HTTPStatus.BAD_REQUEST)
            return
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if len(parts) == 3 and parts[:2] == ["api", "targets"]:
            try:
                self.handle_target_update(parts[2], payload)
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                self.send_json(error_payload("TARGET_NOT_SAVED", "External target was rejected and not changed."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json(error_payload("METHOD_NOT_ALLOWED", "Only defined configuration actions are available."), HTTPStatus.METHOD_NOT_ALLOWED)

    def do_DELETE(self):  # noqa: N802
        if not self.write_allowed():
            return
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
        if len(parts) == 4 and parts[:2] == ["api", "internal-ssh"]:
            try:
                self.handle_internal_ssh_delete(parts[2], parts[3])
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                self.send_json(error_payload("INTERNAL_SSH_REMOVE_FAILED", str(error) or "Internal SSH override was not removed."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if len(parts) == 3 and parts[:2] == ["api", "targets"]:
            try:
                self.handle_target_delete(parts[2])
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                self.send_json(error_payload("TARGET_NOT_REMOVED", "External target was not removed."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        self.send_json(error_payload("METHOD_NOT_ALLOWED", "Only defined target actions are available."), HTTPStatus.METHOD_NOT_ALLOWED)

    do_PATCH = do_PUT

    def log_message(self, format_string, *args):
        return


def parse_args():
    parser = argparse.ArgumentParser(description="Serve the Ultimate Updater status and action preview.")
    parser.add_argument("--status-file", type=Path, default=DEFAULT_STATUS_FILE)
    parser.add_argument("--config-file", type=Path, default=DEFAULT_CONFIG_FILE)
    parser.add_argument("--inventory-file", type=Path, default=DEFAULT_INVENTORY_FILE)
    parser.add_argument("--inventory-script", type=Path, default=DEFAULT_INVENTORY_SCRIPT)
    parser.add_argument("--external-script", type=Path, default=DEFAULT_EXTERNAL_SCRIPT)
    parser.add_argument("--asset-dir", type=Path, default=DEFAULT_ASSET_DIR)
    parser.add_argument("--cli", type=Path, default=DEFAULT_CLI, help="ultimate-updater CLI path")
    parser.add_argument("--job-runner", type=Path, default=DEFAULT_JOB_RUNNER)
    parser.add_argument("--jobs-dir", type=Path, default=DEFAULT_JOBS_DIR)
    parser.add_argument("--auth-file", type=Path, default=DEFAULT_AUTH_FILE)
    parser.add_argument("--bind", default=DEFAULT_BIND, help="bind address (default: localhost)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    return parser.parse_args()


def main():
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    try:
        tls_context, tls_source, tls_cert, tls_fallback_reason = build_tls_context()
    except TLSConfigurationError as error:
        print(f"WebUI TLS configuration error: {error}", flush=True)
        raise SystemExit(78)
    server = ThreadingHTTPServer((args.bind, args.port), StatusHandler)
    server.tls_enabled = tls_context is not None
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    server.status_file, server.cli = args.status_file, args.cli
    server.config_file, server.inventory_file = args.config_file, args.inventory_file
    server.internal_ssh_file = args.config_file.parent / "internal-ssh.conf"
    server.backup_state_file = DEFAULT_BACKUP_STATE_FILE
    server.inventory_script, server.external_script = args.inventory_script, args.external_script
    server.tag_filter_script = args.config_file.parent / "tag-filter.sh"
    server.asset_dir = args.asset_dir
    server.job_runner, server.jobs_dir = args.job_runner, args.jobs_dir
    server.update_script = args.config_file.parent / "update.sh"
    server.version_cache = None
    server.auth = AuthStore(args.auth_file)
    if tls_context is not None:
        print(f"HTTPS enabled; certificate source: {tls_source}; certificate: {tls_cert}", flush=True)
        protocol = "https"
    else:
        print(f"HTTPS unavailable; using HTTP fallback: {tls_fallback_reason}", flush=True)
        protocol = "http"
    print(f"Ultimate Updater UI: {protocol}://{args.bind}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
