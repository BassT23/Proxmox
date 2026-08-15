#!/usr/bin/env python3
"""Small standard-library web UI for status and session-independent actions."""

import argparse
import fcntl
import json
import os
import re
import shlex
import stat
import subprocess
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


DEFAULT_STATUS_FILE = Path("/etc/ultimate-updater/status.json")
DEFAULT_CONFIG_FILE = Path("/etc/ultimate-updater/update.conf")
DEFAULT_INVENTORY_FILE = Path("/etc/ultimate-updater/targets.conf")
DEFAULT_INVENTORY_SCRIPT = Path("/etc/ultimate-updater/target-inventory.sh")
DEFAULT_EXTERNAL_SCRIPT = Path("/etc/ultimate-updater/external-apt.sh")
DEFAULT_ASSET_DIR = Path("/etc/ultimate-updater/web-ui/assets")
DEFAULT_CLI = Path("/usr/local/sbin/ultimate-updater")
DEFAULT_JOB_RUNNER = Path("/etc/ultimate-updater/job-runner.sh")
DEFAULT_JOBS_DIR = Path("/var/lib/ultimate-updater/jobs")
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765
TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
JOB_RE = re.compile(r"^ultimate-updater-update-[A-Za-z0-9_.-]+$")
HOST_RE = re.compile(r"^[A-Za-z0-9_.:-]+$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")

CONFIG_BOOLEAN_KEYS = {
    "CHECK_WITH_HOST", "CHECK_WITH_LXC", "CHECK_WITH_VM",
    "CHECK_RUNNING_CONTAINER", "CHECK_STOPPED_CONTAINER",
    "CHECK_RUNNING_VM", "CHECK_STOPPED_VM", "CHECK_PAUSED_VM",
    "REBOOT_IF_NEEDED", "EMAIL_DAILY_CHECK", "EMAIL_NO_UPDATES",
    "EMAIL_ONLY_SECURITY", "EMAIL_ONLY_ERROR",
}
CONFIG_INTEGER_KEYS = {"LXC_START_DELAY", "VM_START_DELAY"}
CONFIG_STRING_KEYS = {
    "ONLY_UPDATE_CHECK", "EXCLUDE_UPDATE_CHECK", "BACKUP_STORAGE",
    "EMAIL_USER", "EMAIL_SENDER",
}
CONFIG_KEYS = CONFIG_BOOLEAN_KEYS | CONFIG_INTEGER_KEYS | CONFIG_STRING_KEYS
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
    :root { color-scheme:dark; --bg:#0b1020; --panel:#151d34e8; --strong:#19233f; --text:#edf3ff; --muted:#91a0bd; --line:#94a3b82e; --accent:#73a7ff; --good:#55d39a; --warn:#f7c66b; --bad:#ff7e8b; font-family:Inter,ui-sans-serif,system-ui,sans-serif; }
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
    .pill { border-radius:999px; padding:5px 9px; font-size:.7rem; font-weight:750; white-space:nowrap } .pill.good { color:var(--good); background:#55d39a1f } .pill.warn { color:var(--warn); background:#f7c66b1f } .pill.bad { color:var(--bad); background:#ff7e8b1f } .pill.neutral { color:var(--muted); background:#aab7cf1f }
    .target-info,.detail-grid { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:20px } .target-info span,.detail-grid span { display:block; color:var(--muted); font-size:.72rem; margin-bottom:4px } strong { overflow-wrap:anywhere }
    .actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:18px } button { border:1px solid var(--line); border-radius:9px; padding:9px 12px; color:var(--text); background:#ffffff0d; cursor:pointer; font:inherit; font-size:.82rem } button:hover:not(:disabled),button:focus-visible { border-color:var(--accent); outline:2px solid #73a7ff55 } button.primary { background:#73a7ff24; border-color:#73a7ff88 } button:disabled { cursor:not-allowed; opacity:.45 }
    .details,.jobs { border-radius:16px; padding:20px; margin-top:18px } .details h3 { margin:0 0 15px } .details-heading { display:flex; align-items:center; gap:12px; justify-content:space-between } .details-heading h3 { margin:0 } .details-close { padding:7px 10px; font-size:.72rem; color:var(--muted) } .detail-sections { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:16px } .detail-sections section { min-width:0; padding-top:12px; border-top:1px solid #94a3b815 } .detail-sections h4 { margin:0; font-size:.78rem; color:var(--accent) } .detail-sections .detail-grid { grid-template-columns:1fr; gap:10px; margin-top:10px } .error-text { color:var(--bad); white-space:pre-wrap; overflow-wrap:anywhere }
    .job { display:grid; grid-template-columns:1.6fr 1fr .9fr auto; gap:10px; align-items:center; padding:11px 0; border-bottom:1px solid var(--line); font-size:.82rem } .job:last-child { border-bottom:0 } .job code { overflow-wrap:anywhere } .job small { color:var(--muted) } .log { max-height:220px; overflow:auto; white-space:pre-wrap; background:#00000045; border-radius:8px; padding:12px; margin-top:12px; color:#cbd5e1; font: .75rem ui-monospace,monospace }
    .empty { border:1px dashed var(--line); border-radius:16px; padding:30px; text-align:center; color:var(--muted) } footer { font-size:.75rem; margin-top:28px }
    @media (max-width:720px) { main { width:calc(100% - 22px); padding-top:25px } header { display:block } .meta { text-align:left; margin-top:15px } .summary { grid-template-columns:repeat(2,1fr) } .job { grid-template-columns:1fr 1fr } .job button { grid-column:span 2; width:100% } }
    .app-main { width:min(1600px,100%); margin:0 auto; padding:34px clamp(18px,4vw,52px) 54px } .app-header { display:flex; justify-content:space-between; gap:20px; align-items:end; margin-bottom:26px } .systems-panel { padding:22px; border:1px solid var(--line); border-radius:18px; background:#151d34aa; box-shadow:0 18px 50px #00000029 } .view-note { color:var(--muted); font-size:.75rem } .node-group,.external-group { margin-top:18px; border:1px solid var(--line); border-radius:14px; overflow:hidden; background:#0e162b99 } .node-group:not(.open) { min-height:98px } .group-header { display:flex; align-items:center; justify-content:space-between; gap:12px; min-height:96px; padding:15px 16px; cursor:pointer } .group-header:hover { background:#73a7ff0d } .group-toggle { display:grid; place-items:center; flex:0 0 auto; width:38px; height:38px; padding:0; border:1px solid var(--line); border-radius:10px; color:var(--accent); background:#73a7ff0d } .group-toggle:hover { background:#73a7ff22 } .group-title { display:flex; align-items:center; gap:10px; flex:1; min-width:0 } .group-title strong { display:block; font-size:1rem; overflow-wrap:anywhere } .group-title small { display:block; color:var(--muted); font-size:.72rem; margin-top:4px } .group-summary { display:flex; align-items:center; gap:12px; color:var(--muted); font-size:.75rem; white-space:nowrap } .chevron { display:block; color:var(--accent); font-size:1.35rem; line-height:1; transition:transform .16s ease } .node-group.open .chevron,.external-group.open .chevron { transform:rotate(90deg) } .group-body { display:none; padding:0 12px 12px } .node-group.open .group-body,.external-group.open .group-body { display:block } .guest-list { display:grid; gap:6px } .target-row { display:grid; grid-template-columns:minmax(150px,1.5fr) .7fr .8fr .8fr .9fr auto; align-items:center; gap:10px; padding:10px 12px; border-top:1px solid #94a3b815; font-size:.78rem } .target-row:hover { background:#73a7ff0b } .target-row .target-name { font-size:.82rem } .target-row .target-id { margin-top:2px } .row-muted { color:var(--muted); font-size:.72rem } .row-actions { display:flex; justify-content:flex-end; gap:6px } .row-actions button { padding:7px 9px; font-size:.72rem } .target-card { min-height:205px; display:flex; flex-direction:column } .target-card .actions { margin-top:auto } .target-card .target-info { margin-top:15px } .external-group { grid-column:1 / -1; margin-top:20px } .external-group .group-body { padding-top:2px } .job-toggle { display:flex; align-items:center; gap:10px; border:0; padding:0; background:transparent; color:var(--text); font-weight:700; font-size:1rem } .job-count { color:var(--muted); font-size:.74rem; font-weight:500 } .jobs.collapsed .job-list { display:none } .job-list { margin-top:12px } .job-summary { color:var(--muted); font-size:.75rem } .detail-grid { grid-template-columns:repeat(3,1fr) }
    @media (max-width:900px) { .target-row { grid-template-columns:minmax(140px,1.4fr) .8fr .8fr auto; } .target-row .row-os { display:none } }
    @media (max-width:620px) { .app-main { padding:24px 11px 38px } .app-header { display:block } .meta { text-align:left; margin-top:13px } .systems-panel { padding:13px } .section-title { align-items:flex-start } .view-note { display:none } .group-summary { gap:6px; font-size:.68rem } .target-row { grid-template-columns:1fr auto; gap:5px 8px; padding:11px 8px } .target-row > :nth-child(2),.target-row > :nth-child(3),.target-row > :nth-child(4) { display:none } .row-actions { grid-column:2; grid-row:1 / span 2 } .row-actions button { min-height:38px } .detail-grid { grid-template-columns:1fr 1fr } }
    .brand-lockup { display:flex; align-items:flex-start; gap:16px; min-width:0 } .brand-logo { display:none } .brand-header-art { display:block; width:min(300px,70vw); height:auto; flex:0 0 auto; filter:drop-shadow(0 6px 14px #0005) } .brand-copy { min-width:0; padding-top:7px } .management-grid { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:18px; margin-top:18px } .management-panel { border:1px solid var(--line); border-radius:16px; padding:20px; background:var(--panel); box-shadow:0 18px 50px #00000029 } .management-panel h2 { margin:0 } .management-panel .section-title { margin-bottom:16px } .management-form { display:none; gap:14px; grid-template-columns:1fr; margin-top:14px } .management-form.open { display:grid } .management-form label { color:var(--muted); font-size:.75rem } .management-form input,.management-form select { display:block; width:100%; margin-top:5px; border:1px solid var(--line); border-radius:8px; padding:9px 10px; color:var(--text); background:#0b1224; font:inherit } .management-form .form-wide { grid-column:1/-1 } .management-form .form-actions { display:flex; gap:8px; grid-column:1/-1 } .managed-target { display:flex; justify-content:space-between; align-items:center; gap:10px; padding:10px 0; border-top:1px solid #94a3b815; font-size:.8rem } .managed-target:first-child { border-top:0 } .managed-target small { color:var(--muted); display:block; margin-top:3px } .managed-actions { display:flex; flex-wrap:wrap; gap:6px; justify-content:flex-end } .managed-actions button { padding:7px 9px; font-size:.72rem } .settings-group { border-top:1px solid var(--line); padding-top:15px; margin-top:15px } .settings-group:first-child { border-top:0; padding-top:0; margin-top:0 } .settings-group h3 { margin:0; font-size:.88rem } .settings-group p { color:var(--muted); font-size:.72rem; margin:5px 0 11px } .config-fields { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px 18px } .config-field { display:grid; grid-template-columns:auto 1fr; align-items:center; gap:8px; min-width:0; color:var(--muted); font-size:.78rem } .config-field input[type=checkbox] { grid-column:1; accent-color:var(--accent); width:17px; height:17px } .config-field input[type=text],.config-field input[type=number] { grid-column:2; min-width:0; border:1px solid var(--line); border-radius:8px; padding:8px; color:var(--text); background:#0b1224; font:inherit } .config-field input[type=text] { width:100% } .config-field .field-label { grid-column:1 / -1; grid-row:1; padding-left:25px } .config-field input[type=checkbox] + .field-label { grid-column:2; padding-left:0 } .config-field .field-unit { grid-column:2; color:var(--muted); font-size:.7rem; margin-top:-5px } .config-actions { display:flex; gap:8px; margin-top:18px; padding-top:14px; border-top:1px solid var(--line) } .management-message { color:var(--muted); font-size:.76rem; min-height:1.2em; margin-top:10px } .management-message.error { color:var(--bad) } .modal-backdrop { position:fixed; inset:0; z-index:5; display:none; place-items:center; padding:18px; background:#030712aa } .modal-backdrop.open { display:grid } .modal { width:min(520px,100%); border:1px solid var(--line); border-radius:16px; padding:20px; background:#151d34; box-shadow:0 24px 80px #0008 } .modal h3 { margin:0 0 15px } .modal .form-actions { display:flex; gap:8px; margin-top:14px } .modal-close { margin-left:auto }
    @media (max-width:760px) { .management-grid { grid-template-columns:1fr } .config-fields,.management-form { grid-template-columns:1fr } .management-form .form-wide { grid-column:auto } .management-form .form-actions { grid-column:auto } .managed-target { align-items:flex-start; flex-direction:column } .managed-actions { justify-content:flex-start } }
    .config-fields { grid-template-columns:repeat(2,minmax(0,1fr)); gap:12px 18px } .config-field { grid-template-columns:minmax(0,1fr) auto; gap:7px 8px } .config-field input[type=checkbox] { grid-column:1; grid-row:1; justify-self:start } .config-field input[type=text],.config-field input[type=number] { grid-column:1 / -1; grid-row:2; width:100% } .config-field .field-label { grid-column:1 / -1; grid-row:1; min-width:0; padding-left:0 } .config-field input[type=checkbox] + .field-label { grid-column:2; justify-self:start } .config-field .field-unit { grid-column:1 / -1; grid-row:3; margin-top:-3px }
    .node-grid { display:grid; grid-column:1/-1; width:100%; min-width:0; grid-template-columns:repeat(3,minmax(0,1fr)); gap:14px; justify-content:stretch } .node-grid > .node-group { width:100%; min-width:0 } .node-group { margin-top:0; min-height:0 !important } .node-group .group-header,.external-group .group-header { display:grid; grid-template-columns:42px minmax(0,1fr) auto; min-height:98px } .node-group .group-title small,.external-group .group-title small { white-space:nowrap } .node-group .group-summary { display:grid; grid-template-columns:auto auto; grid-template-rows:auto auto; gap:4px 8px; align-items:center } .node-group .group-summary .node-details { grid-column:1/-1; justify-self:end } .guest-panel { grid-column:1/-1; width:100%; min-width:0; margin-top:0; border:1px solid var(--line); border-radius:14px; overflow:hidden; background:#0e162b99 } .guest-panel-title { padding:13px 16px; color:var(--text); font-size:.78rem; font-weight:750; border-bottom:1px solid var(--line); background:#151d34aa } .guest-panel .guest-list { padding:0 12px 12px }
    @media (max-width:1180px) { .node-grid { grid-template-columns:repeat(2,minmax(280px,1fr)) } }
    .node-group .group-toggle,.external-group .group-toggle { border-color:transparent; background:transparent; border-radius:50%; width:42px; height:42px } .node-group .group-toggle:hover,.external-group .group-toggle:hover { background:#73a7ff18 } .chevron { width:12px; height:12px; border-right:2px solid currentColor; border-bottom:2px solid currentColor; transform:rotate(-45deg); transition:transform .16s ease } .node-group.open .chevron,.external-group.open .chevron { transform:rotate(45deg) } .node-group .group-summary .node-details { background:transparent; color:var(--muted); padding:7px 10px; font-size:.72rem }
    .target-row { grid-template-columns:minmax(200px,1.4fr) .8fr .75fr .75fr minmax(180px,1.1fr) auto; min-width:720px } .guest-panel .guest-list { overflow-x:auto } .target-row > div { min-width:0 } .target-row .row-os strong,.target-row .row-muted { overflow-wrap:anywhere }
    .target-field { display:flex; flex-direction:column; gap:3px; min-width:0 } .target-label { color:var(--muted); font-size:.68rem; line-height:1.15; font-weight:650 } .target-field strong { font-size:.78rem; font-weight:400 } .target-status { justify-content:center } .target-status .pill { align-self:flex-start } .reboot-required { color:var(--warn) } .row-last-check strong { white-space:normal } .management-grid.config-open { grid-template-columns:1fr } #managed-targets > .empty { padding:18px; border-radius:10px; font-size:.78rem }
    .node-group .group-title strong { white-space:nowrap; overflow-wrap:normal }
    @media (max-width:620px) { .brand-lockup { gap:11px } .brand-header-art { width:min(260px,82vw) } .brand-copy { padding-top:0 } .subtitle { margin-top:9px; font-size:.82rem } .node-grid { grid-template-columns:1fr } .node-group .group-header { display:grid; grid-template-columns:42px minmax(0,1fr); gap:8px 10px; min-height:98px } .node-group .group-toggle { grid-column:1; grid-row:1 / span 2 } .node-group .group-title { grid-column:2; grid-row:1 } .node-group .group-summary { grid-column:2; grid-row:2; width:100%; justify-content:space-between; white-space:normal } .node-group .group-summary .node-details { margin-left:auto } .guest-panel { margin-top:0 } .guest-panel .guest-list { padding:0 8px 8px } .target-row { min-width:0; grid-template-columns:1fr auto; } .target-row .target-status { grid-column:1/-1; display:block } .target-row .target-field { display:grid; grid-template-columns:minmax(80px,.65fr) minmax(0,1.35fr); align-items:baseline; gap:8px; } .target-row .target-field .target-label { margin:0 } .target-row .row-os,.target-row .row-last-check { grid-column:1/-1; display:grid; grid-template-columns:minmax(80px,.65fr) minmax(0,1.35fr); align-items:baseline; gap:8px; } .target-row .row-actions { grid-column:1/-1; justify-content:flex-start; } .detail-sections { grid-template-columns:1fr; gap:12px } .details { padding:14px } }
    .settings-group .boolean-fields,.settings-group .value-fields { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px 12px } .settings-group .value-fields { margin-top:10px; padding-top:10px; border-top:1px solid #94a3b815 } .config-field.boolean-field { display:flex; align-items:center; gap:8px; min-height:34px; padding:6px 8px; border:1px solid #94a3b815; border-radius:8px; background:#ffffff05 } .config-field.boolean-field input[type=checkbox] { flex:0 0 auto; width:17px; height:17px; margin:0; accent-color:var(--accent) } .config-field.boolean-field .field-label { padding:0; min-width:0; cursor:pointer } .settings-group .value-fields .config-field { display:grid }
    @media (max-width:760px) { .config-fields { grid-template-columns:1fr } .settings-group .boolean-fields,.settings-group .value-fields { grid-template-columns:1fr } }
    .app-header { display:grid; grid-template-columns:minmax(0,1fr) auto; column-gap:24px; align-items:start; margin-bottom:10px } .brand-header-art { width:min(260px,70vw) } .brand-copy { padding-top:0 } .subtitle { margin-top:5px } .app-header .meta { max-width:360px; padding-top:10px; align-self:start }
    @media (max-width:760px) { .app-header { display:block; margin-bottom:10px } .app-header .meta { max-width:none; padding-top:0 } }
    @media (max-width:620px) { .brand-header-art { width:min(250px,82vw) } .subtitle { margin-top:5px } .app-header .meta { margin-top:8px } }
    .dashboard-header { display:block; margin-bottom:18px; padding:20px 22px 18px; border:1px solid var(--line); border-radius:18px; background:#151d34aa; box-shadow:0 18px 50px #00000029 } .dashboard-header-top { display:grid; grid-template-columns:minmax(0,1fr) auto; align-items:start; gap:20px } .dashboard-brand { min-width:0 } .dashboard-brand .brand-lockup { gap:16px } .dashboard-brand .brand-header-art { width:min(370px,70vw) } .dashboard-brand .subtitle { margin:5px 0 0; max-width:650px } .dashboard-meta { align-self:start; max-width:360px; padding-top:10px; color:var(--muted); font-size:.82rem; text-align:right } .dashboard-kpis { margin:16px 0 0; }
    @media (max-width:760px) { .dashboard-header { padding:16px 14px 15px; margin-bottom:14px } .dashboard-header-top { display:block } .dashboard-brand .brand-header-art { width:min(270px,82vw) } .dashboard-meta { max-width:none; padding-top:0; margin-top:8px; text-align:left; font-size:.76rem } .dashboard-kpis { margin-top:14px } }
  </style>
</head>
<body>
  <main class="app-main" id="dashboard">
    <header class="dashboard-header"><div class="dashboard-header-top"><div class="dashboard-brand"><div class="brand-lockup"><div class="brand-copy"><img class="brand-header-art" src="/assets/ultimate-updater-header.png" alt="Ultimate Updater"><h1 class="visually-hidden">Ultimate Updater</h1></div></div><p class="subtitle">A clear overview of updates across your systems.</p></div><div class="dashboard-meta" id="generated">Loading status…</div></div><section class="summary dashboard-kpis"><div class="metric"><strong id="total">–</strong><span>known systems</span></div><div class="metric"><strong id="online">–</strong><span>reachable</span></div><div class="metric"><strong id="updates">–</strong><span>available updates</span></div><div class="metric"><strong id="attention">–</strong><span>needs attention</span></div></section></header>
    <div id="notice" hidden></div>
    <section id="systems" class="systems-panel"><div class="section-title"><div><h2>Systems</h2><span class="hint">Organized by Proxmox node and external target</span></div><span class="view-note">Checks and updates use the existing CLI</span></div><div id="targets" class="targets"></div><section id="details" class="details" hidden></section></section>
    <section class="management-grid">
      <section class="management-panel" id="config-panel"><div class="section-title"><div><h2>Configuration</h2><span class="hint">Known settings only · update.conf remains the source of truth</span></div><button id="config-open">Open settings</button></div><form id="config-form" class="management-form"></form><div id="config-message" class="management-message"></div></section>
      <section class="management-panel" id="external-panel"><div class="section-title"><div><h2>External systems</h2><span class="hint">SSH targets from targets.conf</span></div><button id="target-add">+ Add system</button></div><div id="managed-targets"></div><form id="target-form" class="management-form"></form><div id="target-message" class="management-message"></div></section>
    </section>
    <section id="jobs" class="jobs" hidden></section>
    <footer>Local action preview · status: <code>/etc/ultimate-updater/status.json</code> · jobs: <code>/var/lib/ultimate-updater/jobs</code></footer>
  </main>
  <script>
    const labels={ok:['Healthy','good'],updates_available:['Updates available','warn'],offline:['Offline','bad'],unsupported:['Unsupported','neutral'],not_checked:['Not checked','neutral'],error:['Error','bad']};
    const text=(v,f='Unknown')=>v===null||v===undefined||v===''?f:String(v); const esc=v=>text(v,'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const date=v=>{if(!v)return'Unknown';const d=new Date(v);return Number.isNaN(d.getTime())?String(v):d.toLocaleString()}; const statusLabel=v=>labels[v]||['Unknown','neutral']; const set=(id,v)=>document.getElementById(id).textContent=v;
    const LOG_BOTTOM_TOLERANCE=10;
    let currentStatus={targets:[]}, jobs=[], pollTimer, openJobLogId=null, logAutoFollow=true, logScrollTop=0, suppressLogScroll=false, finalLogLoaded=new Set(), logLoading=new Set();
    function notice(message,error=false){const n=document.getElementById('notice');n.hidden=false;n.textContent=message;n.className=error?'notice error':'notice'}
    function running(target){return jobs.some(j=>j.target===target&&j.state==='running')}
    function renderDetails(t){const n=document.getElementById('details'),[label,tone]=statusLabel(t.check_status),e=t.error?`${text(t.error.code,'')}${t.error.message?': '+t.error.message:''}`:'None';n.hidden=false;n.innerHTML=`<h3>${esc(t.id)}</h3><div class="detail-grid"><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Transport</span><strong>${esc(t.transport)}</strong></div><div><span>Operating system</span><strong>${esc(t.os)}</strong></div><div><span>Updater</span><strong>${esc(t.updater)}</strong></div><div><span>Check status</span><strong class="pill ${tone}">${label}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div><div><span>Reboot required</span><strong>${t.reboot_required===null?'Unknown':t.reboot_required?'Yes':'No'}</strong></div><div><span>Last update</span><strong>${esc(t.last_update&&t.last_update.status)}</strong></div><div><span>Error</span><strong class="error-text">${esc(e)}</strong></div></div>`;n.scrollIntoView({behavior:'smooth',block:'nearest'})}
    async function action(path,update=false){if(update&&!confirm(`Start update for "${path.split('/').pop()}"?`))return;try{const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Action failed');notice(d.message||'Action accepted.');await loadStatus();await loadJobs()}catch(e){notice(e.message,true)}}
    function render(data){currentStatus=data;const ts=Array.isArray(data.targets)?data.targets:[];set('total',ts.length);set('online',ts.filter(t=>t.reachable===true).length);set('updates',ts.map(t=>t.updates&&t.updates.available).filter(Number.isInteger).reduce((a,v)=>a+v,0));set('attention',ts.filter(t=>t.check_status!=='ok').length);set('generated',`Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);const list=document.getElementById('targets');list.replaceChildren();if(!ts.length){list.innerHTML='<div class="empty">No target status is available yet. Run a check to populate the view.</div>';return}for(const t of ts){const [label,tone]=statusLabel(t.check_status),u=t.updates&&Number.isInteger(t.updates.available)?t.updates.available:'Unknown';const card=document.createElement('article');card.className='target-card';card.innerHTML=`<div class="target-top"><div><div class="target-name">${esc(t.id)}</div><div class="target-id">${esc(t.os)} · ${esc(t.transport)}</div></div><span class="pill ${tone}">${label}</span></div><div class="target-info"><div><span>Updates</span><strong>${u}</strong></div><div><span>Reachability</span><strong>${t.reachable===true?'Online':t.reachable===false?'Offline':'Unknown'}</strong></div><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div></div><div class="actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Update running':'Start update'}</button></div>`;card.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});card.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const b=card.querySelector('.update');b.disabled=running(t.id)||!TARGET_UPDATEABLE(t);b.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});list.appendChild(card)}}
    function TARGET_UPDATEABLE(t){return ['ok','updates_available'].includes(t.check_status)}
    function rememberLogScroll(node){if(suppressLogScroll||!node.isConnected||node.id!==`log-${openJobLogId}`)return;const distance=node.scrollHeight-node.scrollTop-node.clientHeight;logAutoFollow=distance<=LOG_BOTTOM_TOLERANCE;logScrollTop=node.scrollTop}
    function attachLogScroll(node){node.addEventListener('scroll',()=>rememberLogScroll(node));}
    async function loadJobLog(unit,node){const job=jobs.find(j=>j.unit===unit),final=job&&job.state!=='running';if(final&&finalLogLoaded.has(unit)||logLoading.has(unit))return;if(!final)finalLogLoaded.delete(unit);logLoading.add(unit);try{const r=await fetch(`/api/jobs/${encodeURIComponent(unit)}/log`),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Log unavailable');node.hidden=false;node.textContent=d.log||'(no journal output)';if(logAutoFollow){node.scrollTop=node.scrollHeight}else{node.scrollTop=logScrollTop}logScrollTop=node.scrollTop;if(final)finalLogLoaded.add(unit)}catch(e){notice(e.message,true)}finally{logLoading.delete(unit)}}
    function renderJobs(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;n.hidden=false;suppressLogScroll=true;n.innerHTML='<div class="section-title"><h2>Update jobs</h2><span class="hint">Server-side state · safe across browser/device changes</span></div>'+jobs.map(j=>{const open=j.unit===openJobLogId;return `<div class="job"><code>${esc(j.unit)}</code><span>${esc(j.target)}</span><span class="pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}">${esc(j.state)}</span><button data-job="${esc(j.unit)}">${open?'Hide log':'Show log'}</button><div class="log" id="log-${esc(j.unit)}"${open?'':' hidden'}></div></div>`}).join('');suppressLogScroll=false;n.querySelectorAll('button[data-job]').forEach(b=>b.addEventListener('click',async()=>{const unit=b.dataset.job;const node=document.getElementById(`log-${unit}`);if(openJobLogId===unit){openJobLogId=null;node.hidden=true;b.textContent='Show log';return}openJobLogId=unit;logAutoFollow=true;logScrollTop=0;node.hidden=false;b.textContent='Hide log';await loadJobLog(unit,node);attachLogScroll(node)}));if(openJobLogId){const node=document.getElementById(`log-${openJobLogId}`);if(node){node.scrollTop=logAutoFollow?node.scrollHeight:logScrollTop;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    async function loadStatus(){try{const r=await fetch('/api/status',{cache:'no-store'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Status unavailable');render(d)}catch(e){notice(e.message,true);set('generated','Status unavailable');document.getElementById('targets').innerHTML='<div class="empty">The status file is missing or invalid.</div>'}}
    async function loadJobs(){try{const r=await fetch('/api/jobs',{cache:'no-store'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Jobs unavailable');jobs=Array.isArray(d.jobs)?d.jobs:[];renderJobs();clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,jobs.some(j=>j.state==='running')?2000:10000);render(currentStatus)}catch(e){clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,10000)}}
    loadStatus();loadJobs();
  </script>
  <div id="target-modal" class="modal-backdrop" role="dialog" aria-modal="true"><form id="target-modal-form" class="modal"><div style="display:flex;align-items:center;gap:10px"><h3 id="target-modal-title">External system</h3><button type="button" class="modal-close" id="target-modal-cancel">Close</button></div><div class="management-form open"><label>Name<input name="id" required pattern="[A-Za-z0-9][A-Za-z0-9_.-]*"></label><label>Host / IP<input name="host" required pattern="[A-Za-z0-9_.:-]+"></label><label>SSH user<input name="user" required pattern="[A-Za-z_][A-Za-z0-9_.-]*"></label><label>SSH port<input name="port" type="number" min="1" max="65535" value="22" required></label><div class="form-actions"><button type="submit" class="primary">Save</button><button type="button" id="target-modal-test">Test connection</button></div><div id="target-modal-message" class="management-message form-wide"></div></div></form></div>
  <script>
    let openNodes=new Set(), jobsExpanded=false, openDetailId=null;
    const nodeLabel=t=>String(t.id||'').replace(/^host:/,'');
    const isProxmoxNode=t=>t&&t.type==='host'&&String(t.id||'').startsWith('host:');
    const targetNode=(t,nodes)=>t.node|| (nodes.length===1?nodeLabel(nodes[0]):null);
    const knownUpdates=t=>t.updates&&Number.isInteger(t.updates.available)?t.updates.available:null;
    const osName=t=>{const value=text(t.os,'Unknown');return value==='Unknown'?value:value.charAt(0).toUpperCase()+value.slice(1)+(t.os_version?` ${t.os_version}`:'')};
    const statusTone=t=>{const [label,tone]=statusLabel(t.check_status);return `<span class="pill ${tone}">${label}</span>`};
    function closeDetails(){const n=document.getElementById('details');openDetailId=null;n.hidden=true;n.replaceChildren()}
    function renderDetails(t){const n=document.getElementById('details');if(openDetailId===t.id){closeDetails();return}const e=t.error?`${text(t.error.code,'')}${t.error.message?': '+t.error.message:''}`:'None';openDetailId=t.id;n.hidden=false;n.innerHTML=`<div class="details-heading"><h3>${esc(t.id)}</h3><button type="button" class="details-close">Close details</button></div><div class="detail-sections"><section><h4>System</h4><div class="detail-grid"><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Node</span><strong>${esc(t.node)}</strong></div><div><span>Transport</span><strong>${esc(t.transport)}</strong></div><div><span>Operating system</span><strong>${esc(osName(t))}</strong></div></div></section><section><h4>Updates</h4><div class="detail-grid"><div><span>Updater</span><strong>${esc(t.updater)}</strong></div><div><span>Available updates</span><strong>${knownUpdates(t)===null?'Unknown':knownUpdates(t)}</strong></div><div><span>Reboot required</span><strong class="${t.reboot_required===true?'reboot-required':''}">${t.reboot_required===null?'Unknown':t.reboot_required?'Yes':'No'}</strong></div></div></section><section><h4>Status</h4><div class="detail-grid"><div><span>Check status</span><strong>${statusTone(t)}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div><div><span>Last update</span><strong>${esc(t.last_update&&t.last_update.status)}</strong></div><div><span>Error</span><strong class="error-text">${esc(e)}</strong></div></div></section></div>`;n.querySelector('.details-close').onclick=closeDetails;n.scrollIntoView({behavior:'smooth',block:'nearest'})}
    function targetRow(t){const row=document.createElement('div');row.className='target-row';row.innerHTML=`<div><div class="target-name">${esc(t.id)}</div><div class="target-id">${esc(t.type)} · ${esc(t.transport)}</div></div><div class="target-field target-status">${statusTone(t)}</div><div class="target-field"><span class="target-label">Updates</span><strong>${knownUpdates(t)===null?'Unknown':knownUpdates(t)}</strong></div><div class="target-field"><span class="target-label">Reboot</span><strong class="${t.reboot_required===true?'reboot-required':''}">${t.reboot_required===true?'Yes':t.reboot_required===false?'No':'Unknown'}</strong></div><div class="target-field row-os"><span class="target-label">OS</span><strong>${esc(osName(t))}</strong></div><div class="target-field row-last-check"><span class="target-label">Last check</span><strong>${esc(date(t.last_check))}</strong></div><div class="row-actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Running':'Update'}</button></div>`;row.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});row.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const b=row.querySelector('.update');b.disabled=running(t.id)||!TARGET_UPDATEABLE(t);b.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});return row}
    function toggleGroup(key){if(openNodes.has(key))openNodes.clear();else{openNodes.clear();openNodes.add(key)}render(currentStatus)}
    function nodeGroup(node,guests,host){const open=openNodes.has(node),updateTotal=[host,...guests].filter(Boolean).map(knownUpdates).filter(Number.isInteger).reduce((a,v)=>a+v,0),card=document.createElement('article');card.className=`node-group${open?' open':''}`;card.innerHTML=`<div class="group-header"><button class="group-toggle" type="button" aria-expanded="${open}" aria-label="${open?'Collapse':'Expand'} ${esc(node)}"><span class="chevron" aria-hidden="true"></span></button><div class="group-title"><div><strong>${esc(node)}</strong><small>Proxmox node · ${guests.length} guest${guests.length===1?'':'s'}</small></div></div><div class="group-summary"><span>${updateTotal} updates</span>${host?statusTone(host):''}<button class="node-details">Details</button></div></div>`;card.querySelector('.group-header').addEventListener('click',e=>{if(e.target.closest('.node-details'))return;toggleGroup(node)});card.querySelector('.group-toggle').addEventListener('click',e=>{e.stopPropagation();toggleGroup(node)});card.querySelector('.node-details').addEventListener('click',e=>{e.stopPropagation();if(host)renderDetails(host)});let panel=null;if(open){panel=document.createElement('section');panel.className='guest-panel';panel.innerHTML=`<div class="guest-panel-title">Guests on ${esc(node)}</div><div class="guest-list"></div>`;guests.forEach(t=>panel.querySelector('.guest-list').appendChild(targetRow(t)))}return{card,panel}}
    function externalGroup(targets){const group=document.createElement('section');const open=openNodes.has('__external__');group.className=`external-group${open?' open':''}`;const updates=targets.map(knownUpdates).filter(Number.isInteger).reduce((a,v)=>a+v,0);group.innerHTML=`<div class="group-header"><button class="group-toggle" type="button" aria-expanded="${open}" aria-label="${open?'Collapse':'Expand'} external systems"><span class="chevron" aria-hidden="true"></span></button><div class="group-title"><div><strong>External systems</strong><small>${targets.length} target${targets.length===1?'':'s'}</small></div></div><div class="group-summary"><span>${updates} updates</span></div></div><div class="group-body"><div class="guest-list"></div></div>`;group.querySelector('.group-header').addEventListener('click',()=>toggleGroup('__external__'));group.querySelector('.group-toggle').addEventListener('click',e=>{e.stopPropagation();toggleGroup('__external__')});targets.forEach(t=>group.querySelector('.guest-list').appendChild(targetRow(t)));return group}
    function render(data){currentStatus=data;const ts=Array.isArray(data.targets)?data.targets:[],nodes=ts.filter(isProxmoxNode),guests=ts.filter(t=>t.type==='lxc'||t.type==='vm'),external=ts.filter(t=>!isProxmoxNode(t)&&t.type!=='lxc'&&t.type!=='vm');set('total',ts.length);set('online',ts.filter(t=>t.reachable===true).length);set('updates',ts.map(knownUpdates).filter(Number.isInteger).reduce((a,v)=>a+v,0));set('attention',ts.filter(t=>t.check_status!=='ok').length);set('generated',`Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);const list=document.getElementById('targets');list.replaceChildren();if(!ts.length){list.innerHTML='<div class="empty">No target status is available yet. Run a check to populate the view.</div>';return}if(nodes.length){const grid=document.createElement('div');grid.className='node-grid';let openPanel=null,assigned=new Set();nodes.forEach(host=>{const node=nodeLabel(host),members=guests.filter(t=>targetNode(t,nodes)===node);members.forEach(t=>assigned.add(t.id));const parts=nodeGroup(node,members,host);grid.appendChild(parts.card);if(parts.panel)openPanel=parts.panel});const unassigned=guests.filter(t=>!assigned.has(t.id));if(unassigned.length){const parts=nodeGroup('Guests without node assignment',unassigned,null);grid.appendChild(parts.card);if(parts.panel)openPanel=parts.panel}list.appendChild(grid);if(openPanel)list.appendChild(openPanel)}else if(guests.length){const grid=document.createElement('div');grid.className='node-grid';const parts=nodeGroup('Guests without node assignment',guests,null);grid.appendChild(parts.card);list.appendChild(grid);if(parts.panel)list.appendChild(parts.panel)}if(external.length)list.appendChild(externalGroup(external))}
    function renderJobs(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;const runningCount=jobs.filter(j=>j.state==='running').length,finished=jobs.length-runningCount;n.hidden=false;suppressLogScroll=true;n.innerHTML=`<div class="section-title"><button class="job-toggle"><span class="chevron" aria-hidden="true"></span><span>Update jobs <span class="job-count">(${runningCount} running, ${finished} finished)</span></span></button><span class="job-summary">Server-side state · safe across browser/device changes</span></div><div class="job-list"></div>`;suppressLogScroll=false;n.classList.toggle('collapsed',!jobsExpanded);n.querySelector('.job-toggle').addEventListener('click',()=>{jobsExpanded=!jobsExpanded;n.classList.toggle('collapsed',!jobsExpanded)});const list=n.querySelector('.job-list');jobs.forEach(j=>{const item=document.createElement('div');item.className='job';const open=j.unit===openJobLogId;item.innerHTML=`<code>${esc(j.unit)}</code><span>${esc(j.target)}</span><span class="pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}">${esc(j.state)}</span><button data-job="${esc(j.unit)}">${open?'Hide log':'Show log'}</button><div class="log" id="log-${esc(j.unit)}"${open?'':' hidden'}></div>`;list.appendChild(item)});n.querySelectorAll('button[data-job]').forEach(b=>b.addEventListener('click',async()=>{const unit=b.dataset.job,node=document.getElementById(`log-${unit}`);jobsExpanded=true;n.classList.remove('collapsed');if(openJobLogId===unit){openJobLogId=null;node.hidden=true;b.textContent='Show log';return}openJobLogId=unit;logAutoFollow=true;logScrollTop=0;node.hidden=false;b.textContent='Hide log';await loadJobLog(unit,node);attachLogScroll(node)}));if(openJobLogId){const node=document.getElementById(`log-${openJobLogId}`);if(node){node.scrollTop=logAutoFollow?node.scrollHeight:logScrollTop;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    document.getElementById('jobs').addEventListener('click',e=>{const button=e.target.closest('button[data-job]');if(button&&button.textContent==='Show log')finalLogLoaded.delete(button.dataset.job)},true);
    function renderJobsStable(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;openJobLogId=null;return}if(openJobLogId&&!jobs.some(j=>j.unit===openJobLogId))openJobLogId=null;n.hidden=false;let list=n.querySelector('.job-list');if(!list||!n.querySelector('.job-toggle')){n.innerHTML='<div class="section-title"><button class="job-toggle"><span class="chevron" aria-hidden="true"></span><span>Update jobs <span class="job-count"></span></span></button><span class="job-summary">Server-side state · safe across browser/device changes</span></div><div class="job-list"></div>';n.querySelector('.job-toggle').addEventListener('click',()=>{jobsExpanded=!jobsExpanded;n.classList.toggle('collapsed',!jobsExpanded)});list=n.querySelector('.job-list')}n.classList.toggle('collapsed',!jobsExpanded);n.querySelector('.job-count').textContent=`(${jobs.filter(j=>j.state==='running').length} running, ${jobs.filter(j=>j.state!=='running').length} finished)`;const existing=new Map([...list.querySelectorAll('.job')].map(item=>[item.dataset.unit,item]));const seen=new Set();for(const j of jobs){let item=existing.get(j.unit);if(!item){item=document.createElement('div');item.className='job';item.dataset.unit=j.unit;item.innerHTML=`<code></code><span></span><span class="pill"></span><button data-job="${esc(j.unit)}">Show log</button><div class="log" id="log-${esc(j.unit)}" hidden></div>`;const button=item.querySelector('button[data-job]');button.addEventListener('click',async()=>{const unit=button.dataset.job,node=document.getElementById(`log-${unit}`);if(openJobLogId===unit){openJobLogId=null;finalLogLoaded.delete(unit);node.hidden=true;button.textContent='Show log';return}openJobLogId=unit;finalLogLoaded.delete(unit);logAutoFollow=true;logScrollTop=0;node.hidden=false;button.textContent='Hide log';await loadJobLog(unit,node);attachLogScroll(node)});list.appendChild(item)}seen.add(j.unit);item.querySelector('code').textContent=j.unit;item.querySelector('code').title=j.unit;item.querySelector('span').textContent=j.owner_node?`${j.target} · ${j.owner_node}`:j.target;const state=item.querySelector('.pill');state.textContent=j.state;state.className=`pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}`;const button=item.querySelector('button[data-job]'),node=item.querySelector('.log'),open=j.unit===openJobLogId;button.textContent=open?'Hide log':'Show log';node.hidden=!open}for(const [unit,item] of existing){if(!seen.has(unit))item.remove()}if(openJobLogId){const job=jobs.find(j=>j.unit===openJobLogId),node=document.getElementById(`log-${openJobLogId}`);if(job&&node){node.hidden=false;loadJobLog(openJobLogId,node).then(()=>{if(openJobLogId===node.id.slice(4))attachLogScroll(node)})}}}
    renderJobs=renderJobsStable;window.renderJobs=renderJobsStable;
    clearTimeout(pollTimer);loadStatus();loadJobs();
  </script>
  <script>
    const configBooleanKeys=['CHECK_WITH_HOST','CHECK_WITH_LXC','CHECK_WITH_VM','CHECK_RUNNING_CONTAINER','CHECK_STOPPED_CONTAINER','CHECK_RUNNING_VM','CHECK_STOPPED_VM','CHECK_PAUSED_VM','REBOOT_IF_NEEDED','EMAIL_DAILY_CHECK','EMAIL_NO_UPDATES','EMAIL_ONLY_SECURITY','EMAIL_ONLY_ERROR'];
    const configNumberKeys=['LXC_START_DELAY','VM_START_DELAY'];
    const configStringKeys=['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK','BACKUP_STORAGE','EMAIL_USER','EMAIL_SENDER'];
    const configLabels={CHECK_WITH_HOST:'Check host',CHECK_WITH_LXC:'Check LXC',CHECK_WITH_VM:'Check VM',CHECK_RUNNING_CONTAINER:'Check running containers',CHECK_STOPPED_CONTAINER:'Check stopped containers',CHECK_RUNNING_VM:'Check running VMs',CHECK_STOPPED_VM:'Check stopped VMs',CHECK_PAUSED_VM:'Check paused VMs',REBOOT_IF_NEEDED:'Reboot if needed',EMAIL_DAILY_CHECK:'Daily email check',EMAIL_NO_UPDATES:'Email when no updates',EMAIL_ONLY_SECURITY:'Email security updates only',EMAIL_ONLY_ERROR:'Email errors only',LXC_START_DELAY:'LXC start delay',VM_START_DELAY:'VM start delay',ONLY_UPDATE_CHECK:'Only update-check filter',EXCLUDE_UPDATE_CHECK:'Exclude update-check filter',BACKUP_STORAGE:'Backup storage',EMAIL_USER:'Email recipient',EMAIL_SENDER:'Email sender'};
    const configGroups=[
      {title:'Check scope',hint:'Choose which system classes and guest states are included in checks.',keys:configBooleanKeys.slice(0,8)},
      {title:'Update behavior',hint:'Reboot policy, lifecycle delays, and Proxmox storage selection.',keys:['REBOOT_IF_NEEDED','LXC_START_DELAY','VM_START_DELAY','BACKUP_STORAGE']},
      {title:'Filters',hint:'Tag/filter expressions used to limit checked guests.',keys:['ONLY_UPDATE_CHECK','EXCLUDE_UPDATE_CHECK']},
      {title:'Notifications',hint:'Existing email notification settings only; no credentials are stored here.',keys:['EMAIL_DAILY_CHECK','EMAIL_NO_UPDATES','EMAIL_ONLY_SECURITY','EMAIL_ONLY_ERROR','EMAIL_USER','EMAIL_SENDER']}
    ];
    let managedTargets=[], editingTarget=null;
    function setConfigOpen(open){const form=document.getElementById('config-form'),panel=document.getElementById('config-panel'),button=document.getElementById('config-open');form.classList.toggle('open',open);document.querySelector('.management-grid').classList.toggle('config-open',open);button.textContent=open?'Close settings':'Open settings';button.setAttribute('aria-expanded',String(open));if(open)loadConfig()}
    function managementMessage(id,message,error=false){const n=document.getElementById(id);n.textContent=message||'';n.className=`management-message${error?' error':''}`}
    async function api(path,options={}){const r=await fetch(path,{...options,headers:{'Content-Type':'application/json',...(options.headers||{})}});const d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Request failed');return d}
    function buildConfigForm(values){const form=document.getElementById('config-form');form.innerHTML='';for(const groupData of configGroups){const group=document.createElement('section');group.className='settings-group';group.innerHTML=`<h3>${groupData.title}</h3><p>${groupData.hint}</p>`;const booleanFields=document.createElement('div'),valueFields=document.createElement('div');booleanFields.className='boolean-fields';valueFields.className='value-fields';for(const key of groupData.keys){const label=document.createElement('label');label.className=`config-field${configBooleanKeys.includes(key)?' boolean-field':''}`;const caption=document.createElement('span');caption.className='field-label';caption.textContent=configLabels[key]||key;const input=document.createElement('input');input.name=key;input.dataset.key=key;if(configBooleanKeys.includes(key)){input.type='checkbox';input.checked=values[key]===true;label.append(input,caption)}else{input.type=configNumberKeys.includes(key)?'number':'text';input.value=values[key]??'';if(input.type==='number'){input.min='0';input.max='86400'}label.append(caption,input);if(configNumberKeys.includes(key)){const unit=document.createElement('span');unit.className='field-unit';unit.textContent='seconds';label.append(unit)}else if(key==='BACKUP_STORAGE'){const unit=document.createElement('span');unit.className='field-unit';unit.textContent='Proxmox storage ID, e.g. pbs';label.append(unit)}}(configBooleanKeys.includes(key)?booleanFields:valueFields).appendChild(label)}if(booleanFields.childElementCount)group.appendChild(booleanFields);if(valueFields.childElementCount)group.appendChild(valueFields);form.appendChild(group)}const actions=document.createElement('div');actions.className='config-actions';actions.innerHTML='<button type="submit" class="primary">Save settings</button><button type="button" id="config-close">Cancel</button>';form.appendChild(actions);form.onsubmit=async e=>{e.preventDefault();const next={};for(const input of form.querySelectorAll('[data-key]'))next[input.dataset.key]=input.type==='checkbox'?input.checked:input.type==='number'?Number(input.value):input.value;try{const d=await api('/api/config',{method:'POST',body:JSON.stringify({values:next})});buildConfigForm(d.config);setConfigOpen(false);managementMessage('config-message','Configuration saved.')}catch(error){managementMessage('config-message',error.message,true)}};document.getElementById('config-close').onclick=()=>setConfigOpen(false)}
    async function loadConfig(){try{const d=await api('/api/config');buildConfigForm(d.config)}catch(error){managementMessage('config-message',error.message,true)}}
    function renderManagedTargets(){const box=document.getElementById('managed-targets');if(!managedTargets.length){box.innerHTML='<div class="empty">No external systems configured.</div>';return}box.innerHTML=managedTargets.map(t=>`<div class="managed-target"><div><strong>${esc(t.id)}</strong><small>${esc(t.user)}@${esc(t.host)}:${esc(t.port)} · SSH</small></div><div class="managed-actions"><button data-edit="${esc(t.id)}">Edit</button><button data-test="${esc(t.id)}">Test connection</button><button data-remove="${esc(t.id)}">Remove</button></div></div>`).join('');box.querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>openTargetModal(managedTargets.find(t=>t.id===b.dataset.edit)));box.querySelectorAll('[data-test]').forEach(b=>b.onclick=()=>testTarget(b.dataset.test));box.querySelectorAll('[data-remove]').forEach(b=>b.onclick=()=>removeTarget(b.dataset.remove))}
    async function loadTargets(){try{managedTargets=(await api('/api/targets')).targets||[];renderManagedTargets()}catch(error){managementMessage('target-message',error.message,true)}}
    function openTargetModal(target=null){editingTarget=target;const form=document.getElementById('target-modal-form');form.reset();form.elements.id.value=target?.id||'';form.elements.host.value=target?.host||'';form.elements.user.value=target?.user||'root';form.elements.port.value=target?.port||22;form.elements.id.readOnly=Boolean(target);document.getElementById('target-modal-title').textContent=target?'Edit external system':'Add external system';managementMessage('target-modal-message','');document.getElementById('target-modal').classList.add('open')}
    function closeTargetModal(){document.getElementById('target-modal').classList.remove('open');editingTarget=null}
    async function saveTarget(e){e.preventDefault();const form=e.currentTarget;const payload={id:form.elements.id.value,host:form.elements.host.value,user:form.elements.user.value,port:Number(form.elements.port.value)};try{await api(editingTarget?`/api/targets/${encodeURIComponent(editingTarget.id)}`:'/api/targets',{method:editingTarget?'PUT':'POST',body:JSON.stringify(payload)});closeTargetModal();await loadTargets();await loadStatus();managementMessage('target-message','External target saved.')}catch(error){managementMessage('target-modal-message',error.message,true)}}
    async function removeTarget(id){if(!confirm(`Remove external system "${id}"?`))return;try{await api(`/api/targets/${encodeURIComponent(id)}`,{method:'DELETE'});await loadTargets();await loadStatus();managementMessage('target-message','External target removed.')}catch(error){managementMessage('target-message',error.message,true)}}
    async function testTarget(id){try{const d=await api(`/api/targets/${encodeURIComponent(id)}/test`,{method:'POST',body:'{}'});const t=d.target||{};managementMessage('target-message',`Connection successful · ${t.os||'OS unknown'} · ${t.updater||'updater unknown'}`)}catch(error){managementMessage('target-message',error.message,true)}}
    function targetRow(t){const row=document.createElement('div');row.className='target-row';const external=String(t.type||'').toLowerCase()==='external';row.innerHTML=`<div><div class="target-name">${esc(t.id)}</div><div class="target-id">${esc(t.type)} · ${esc(t.transport)}</div></div><div class="target-field target-status">${statusTone(t)}</div><div class="target-field"><span class="target-label">Updates</span><strong>${knownUpdates(t)===null?'Unknown':knownUpdates(t)}</strong></div><div class="target-field"><span class="target-label">Reboot</span><strong class="${t.reboot_required===true?'reboot-required':''}">${t.reboot_required===true?'Yes':t.reboot_required===false?'No':'Unknown'}</strong></div><div class="target-field row-os"><span class="target-label">OS</span><strong>${esc(osName(t))}</strong></div><div class="target-field row-last-check"><span class="target-label">Last check</span><strong>${esc(date(t.last_check))}</strong></div><div class="row-actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Running':'Update'}</button>${external?'<button class="edit-target">Edit</button><button class="remove-target">Remove</button>':''}</div>`;row.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});row.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const update=row.querySelector('.update');update.disabled=running(t.id)||!TARGET_UPDATEABLE(t);update.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});if(external){row.querySelector('.edit-target').onclick=e=>{e.stopPropagation();openTargetModal(managedTargets.find(x=>x.id===t.id))};row.querySelector('.remove-target').onclick=e=>{e.stopPropagation();removeTarget(t.id)}}return row}
    document.getElementById('config-open').onclick=()=>setConfigOpen(!document.getElementById('config-form').classList.contains('open'));document.getElementById('target-add').onclick=()=>openTargetModal();document.getElementById('target-modal-cancel').onclick=closeTargetModal;document.getElementById('target-modal-test').onclick=()=>{const id=document.querySelector('#target-modal-form [name=id]').value;if(id)testTarget(id)};document.getElementById('target-modal-form').onsubmit=saveTarget;loadConfig();loadTargets();
  </script>
</main></body></html>"""


def error_payload(code, message):
    return {"error": {"code": code, "message": message}}


def parse_state_line(line):
    fields = line.rstrip("\n").split("\t")
    if len(fields) < 6:
        return None
    unit, target, state, started, finished, exit_code = fields[:6]
    owner_node = fields[6] if len(fields) > 6 and fields[6] else None
    return {"unit": unit, "target": target, "state": state,
            "started_at": started or None, "finished_at": finished or None,
            "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else None,
            "owner_node": owner_node, "remote": owner_node is not None}


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
            if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 86400:
                raise ValueError(f"{key} must be an integer between 0 and 86400.")
            normalized[key] = str(value)
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


class StatusHandler(BaseHTTPRequestHandler):
    server_version = "UltimateUpdaterUI/1"

    def send_bytes(self, body, content_type, status=HTTPStatus.OK):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload, status=HTTPStatus.OK):
        self.send_bytes(json.dumps(payload, ensure_ascii=False).encode(), "application/json; charset=utf-8", status)

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

    def run_command(self, args, timeout=300, extra_env=None):
        environment = {**os.environ, "UU_JOB_STATE_DIR": str(self.server.jobs_dir)}
        if extra_env:
            environment.update(extra_env)
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout, check=False,
                              env=environment)

    def jobs(self):
        runner = self.server.job_runner
        if not runner.is_file() or not runner.stat().st_mode & 0o111:
            raise RuntimeError("job runner is not available")
        result = self.run_command([str(runner), "list"], timeout=15)
        if result.returncode:
            raise RuntimeError("job state could not be read")
        rows = [parse_state_line(line) for line in result.stdout.splitlines()]
        return [row for row in rows if row and JOB_RE.fullmatch(row["unit"])]

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

    def handle_config_update(self, payload):
        normalized = validate_config_values(payload.get("values") if isinstance(payload, dict) else None)
        locked_atomic_update(self.server.config_file,
                             lambda content: update_config_text(content, normalized))
        self.send_json({"message": "Configuration saved.", "config": config_value_map(self.config_content())})

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
        if path == "/api/config":
            try:
                self.send_json({"config": config_value_map(self.config_content()), "editable": sorted(CONFIG_KEYS)})
            except (OSError, UnicodeError):
                self.send_json(error_payload("CONFIG_UNAVAILABLE", "Configuration is unavailable."), HTTPStatus.SERVICE_UNAVAILABLE)
            return
        if path == "/api/targets":
            try:
                self.send_json({"targets": self.inventory_data()})
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("TARGETS_INVALID", "External target inventory is invalid or unavailable."), HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if path == "/api/status":
            try:
                with self.server.status_file.open(encoding="utf-8") as source:
                    payload = json.load(source)
                if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
                    raise ValueError
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
        parts = [unquote(part) for part in path.split("/") if part]
        if len(parts) == 4 and parts[:2] == ["api", "jobs"] and parts[3] == "log":
            unit = parts[2]
            try:
                job = self.job_record(unit)
                if not job:
                    raise ValueError
                if job.get("remote"):
                    result = self.run_command([str(self.server.job_runner), "remote-log", unit], timeout=15)
                else:
                    result = self.run_command(["journalctl", "-u", unit, "-n", "200", "--no-pager", "-o", "cat"], timeout=15)
                if result.returncode:
                    raise RuntimeError
                self.send_json({"unit": unit, "log": result.stdout})
            except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("JOB_LOG_UNAVAILABLE", "The requested job log is not available."), HTTPStatus.NOT_FOUND)
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
        if urlsplit(self.path).path == "/api/config":
            try:
                self.handle_config_update(payload)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send_json(error_payload("CONFIG_NOT_SAVED", "Configuration was rejected and not changed."), HTTPStatus.UNPROCESSABLE_ENTITY)
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
            self.action_update(parts[2])
            return
        self.send_json(error_payload("METHOD_NOT_ALLOWED", "Only defined check and update actions are available."), HTTPStatus.METHOD_NOT_ALLOWED)

    def action_check(self, target):
        if not self.valid_target(target):
            self.send_json(error_payload("INVALID_TARGET", "The target name is invalid."), HTTPStatus.BAD_REQUEST)
            return
        try:
            result = self.run_command([str(self.server.cli), "check", target],
                                      extra_env={"STATUS_MODEL_PARTIAL": "true"})
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("CHECK_FAILED", "The check could not be started or completed."), HTTPStatus.BAD_GATEWAY)
            return
        if result.returncode == 3:
            self.send_json(error_payload("TARGET_NOT_FOUND", "The target is not known to the updater."), HTTPStatus.NOT_FOUND)
            return
        self.send_json({"target": target, "state": "completed" if result.returncode == 0 else "failed",
                        "exit_code": result.returncode,
                        "message": "Check completed." if result.returncode == 0 else "Check failed."},
                       HTTPStatus.OK if result.returncode == 0 else HTTPStatus.UNPROCESSABLE_ENTITY)

    def action_update(self, target):
        if not self.valid_target(target):
            self.send_json(error_payload("INVALID_TARGET", "The target name is invalid."), HTTPStatus.BAD_REQUEST)
            return
        try:
            result = self.run_command([str(self.server.cli), "update", target], timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(error_payload("UPDATE_START_FAILED", "The update job could not be started."), HTTPStatus.BAD_GATEWAY)
            return
        output = f"{result.stdout}\n{result.stderr}"
        job_match = re.search(r"^Job:\s*(\S+)", output, re.MULTILINE)
        if result.returncode != 0:
            code = "JOB_ALREADY_RUNNING" if result.returncode == 3 else "UPDATE_START_FAILED"
            message = "An update job is already running for this target." if result.returncode == 3 else "The update job could not be started."
            self.send_json(error_payload(code, message), HTTPStatus.CONFLICT if result.returncode == 3 else HTTPStatus.UNPROCESSABLE_ENTITY)
            return
        if not job_match or not JOB_RE.fullmatch(job_match.group(1)):
            self.send_json(error_payload("INVALID_JOB_RESPONSE", "The updater returned no valid job ID."), HTTPStatus.BAD_GATEWAY)
            return
        self.send_json({"target": target, "job": job_match.group(1), "state": "running", "message": "Update job started."}, HTTPStatus.ACCEPTED)

    def do_PUT(self):  # noqa: N802
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
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
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
    parser.add_argument("--bind", default=DEFAULT_BIND, help="bind address (default: localhost)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    return parser.parse_args()


def main():
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    server = ThreadingHTTPServer((args.bind, args.port), StatusHandler)
    server.status_file, server.cli = args.status_file, args.cli
    server.config_file, server.inventory_file = args.config_file, args.inventory_file
    server.inventory_script, server.external_script = args.inventory_script, args.external_script
    server.asset_dir = args.asset_dir
    server.job_runner, server.jobs_dir = args.job_runner, args.jobs_dir
    print(f"Ultimate Updater UI: http://{args.bind}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
