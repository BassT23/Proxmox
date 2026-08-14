#!/usr/bin/env python3
"""Small read-only browser preview for the Ultimate Updater status model."""

import argparse
import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


DEFAULT_STATUS_FILE = Path("/etc/ultimate-updater/status.json")
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765


PAGE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <title>Ultimate Updater</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1020;
      --panel: rgba(21, 29, 52, .88);
      --panel-strong: #19233f;
      --text: #edf3ff;
      --muted: #91a0bd;
      --line: rgba(148, 163, 184, .18);
      --accent: #73a7ff;
      --good: #55d39a;
      --warn: #f7c66b;
      --bad: #ff7e8b;
      --neutral: #aab7cf;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, sans-serif;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      color: var(--text);
      background: radial-gradient(circle at top right, #1e3567 0, var(--bg) 42rem);
    }
    main { width: min(1180px, calc(100% - 32px)); margin: 0 auto; padding: 38px 0 56px; }
    header { display: flex; justify-content: space-between; gap: 20px; align-items: end; margin-bottom: 28px; }
    .eyebrow { color: var(--accent); font-size: .75rem; font-weight: 750; letter-spacing: .16em; text-transform: uppercase; }
    h1 { margin: 6px 0 0; font-size: clamp(2rem, 5vw, 3.4rem); letter-spacing: -.05em; line-height: 1; }
    .subtitle { color: var(--muted); margin: 12px 0 0; max-width: 580px; }
    .meta { color: var(--muted); font-size: .82rem; text-align: right; }
    .summary { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 28px; }
    .metric, .notice, .details, .target-card { border: 1px solid var(--line); background: var(--panel); box-shadow: 0 18px 50px rgba(0,0,0,.16); }
    .metric { border-radius: 16px; padding: 18px; }
    .metric strong { display: block; font-size: 1.8rem; letter-spacing: -.04em; }
    .metric span { color: var(--muted); font-size: .82rem; }
    .notice { border-radius: 14px; padding: 16px 18px; color: var(--warn); margin-bottom: 20px; }
    .notice.error { color: var(--bad); }
    .section-title { display: flex; justify-content: space-between; align-items: baseline; margin: 0 0 12px; }
    h2 { font-size: 1rem; margin: 0; }
    .hint { color: var(--muted); font-size: .82rem; }
    .targets { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 14px; }
    .target-card { border-radius: 18px; color: var(--text); text-align: left; padding: 18px; cursor: pointer; transition: transform .16s ease, border-color .16s ease, background .16s ease; }
    .target-card:hover, .target-card:focus-visible { transform: translateY(-2px); border-color: var(--accent); background: var(--panel-strong); outline: none; }
    .target-top { display: flex; justify-content: space-between; gap: 12px; align-items: start; }
    .target-name { font-size: 1.05rem; font-weight: 720; overflow-wrap: anywhere; }
    .target-id { color: var(--muted); font: .76rem ui-monospace, SFMono-Regular, monospace; margin-top: 4px; overflow-wrap: anywhere; }
    .pill { border-radius: 999px; padding: 5px 9px; font-size: .7rem; font-weight: 750; white-space: nowrap; }
    .pill.good { color: var(--good); background: rgba(85,211,154,.12); }
    .pill.warn { color: var(--warn); background: rgba(247,198,107,.12); }
    .pill.bad { color: var(--bad); background: rgba(255,126,139,.12); }
    .pill.neutral { color: var(--neutral); background: rgba(170,183,207,.12); }
    .target-info { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 22px; }
    .target-info span, .detail-grid span { display: block; color: var(--muted); font-size: .72rem; margin-bottom: 4px; }
    .target-info strong, .detail-grid strong { font-size: .9rem; overflow-wrap: anywhere; }
    .details { border-radius: 16px; padding: 20px; margin-top: 18px; }
    .details h3 { margin: 0 0 16px; }
    .detail-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
    .error-text { color: var(--bad); white-space: pre-wrap; overflow-wrap: anywhere; }
    .empty { border: 1px dashed var(--line); border-radius: 16px; padding: 32px; text-align: center; color: var(--muted); }
    footer { color: var(--muted); font-size: .75rem; margin-top: 30px; }
    @media (max-width: 720px) {
      main { width: min(100% - 22px, 620px); padding-top: 26px; }
      header { display: block; }
      .meta { text-align: left; margin-top: 16px; }
      .summary { grid-template-columns: repeat(2, 1fr); }
      .detail-grid { grid-template-columns: repeat(2, 1fr); }
    }
  </style>
</head>
<body>
  <main>
    <header>
      <div>
        <div class="eyebrow">Universal Systems · Preview</div>
        <h1>Ultimate Updater</h1>
        <p class="subtitle">A compact, read-only view of the latest status produced by the updater core.</p>
      </div>
      <div class="meta" id="generated">Loading status…</div>
    </header>
    <div id="notice" hidden></div>
    <section class="summary" aria-label="Summary">
      <div class="metric"><strong id="total">–</strong><span>known targets</span></div>
      <div class="metric"><strong id="online">–</strong><span>reachable</span></div>
      <div class="metric"><strong id="updates">–</strong><span>available updates</span></div>
      <div class="metric"><strong id="attention">–</strong><span>needs attention</span></div>
    </section>
    <section>
      <div class="section-title"><h2>Systems</h2><span class="hint">Select a card for details</span></div>
      <div id="targets" class="targets"></div>
    </section>
    <section id="details" class="details" hidden aria-live="polite"></section>
    <footer>Read-only preview · data source: <code>/etc/ultimate-updater/status.json</code></footer>
  </main>
  <script>
    const labels = {
      ok: ['Healthy', 'good'], updates_available: ['Updates available', 'warn'],
      offline: ['Offline', 'bad'], unsupported: ['Unsupported', 'neutral'],
      not_checked: ['Not checked', 'neutral'], error: ['Error', 'bad']
    };
    const text = (value, fallback = 'Unknown') => value === null || value === undefined || value === '' ? fallback : String(value);
    const date = value => {
      if (!value) return 'Unknown';
      const parsed = new Date(value);
      return Number.isNaN(parsed.getTime()) ? String(value) : parsed.toLocaleString();
    };
    const statusLabel = value => labels[value] || ['Unknown', 'neutral'];
    const setText = (id, value) => { document.getElementById(id).textContent = value; };
    function showNotice(message, error = false) {
      const node = document.getElementById('notice');
      node.hidden = false; node.textContent = message; node.className = error ? 'notice error' : 'notice';
    }
    function renderDetails(target) {
      const node = document.getElementById('details');
      const [label, tone] = statusLabel(target.check_status);
      const error = target.error ? `${text(target.error.code, '')}${target.error.message ? ': ' + target.error.message : ''}` : 'None';
      node.hidden = false;
      node.innerHTML = `<h3>${text(target.id)}</h3><div class="detail-grid">
        <div><span>Type</span><strong>${text(target.type)}</strong></div>
        <div><span>Transport</span><strong>${text(target.transport)}</strong></div>
        <div><span>Operating system</span><strong>${text(target.os)}</strong></div>
        <div><span>Updater</span><strong>${text(target.updater)}</strong></div>
        <div><span>Check status</span><strong class="pill ${tone}">${label}</strong></div>
        <div><span>Last check</span><strong>${date(target.last_check)}</strong></div>
        <div><span>Reboot required</span><strong>${target.reboot_required === null ? 'Unknown' : target.reboot_required ? 'Yes' : 'No'}</strong></div>
        <div><span>Last update</span><strong>${text(target.last_update && target.last_update.status)}</strong></div>
        <div><span>Error</span><strong class="error-text">${error}</strong></div>
      </div>`;
      node.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    }
    function render(data) {
      const targets = Array.isArray(data.targets) ? data.targets : [];
      setText('total', targets.length);
      setText('online', targets.filter(item => item.reachable === true).length);
      const knownUpdates = targets.map(item => item.updates && item.updates.available).filter(value => Number.isInteger(value));
      setText('updates', knownUpdates.reduce((sum, value) => sum + value, 0));
      setText('attention', targets.filter(item => !['ok'].includes(item.check_status)).length);
      setText('generated', `Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);
      const list = document.getElementById('targets'); list.replaceChildren();
      if (!targets.length) { list.innerHTML = '<div class="empty">No target status is available yet. Run a check to populate the read-only preview.</div>'; return; }
      for (const target of targets) {
        const [label, tone] = statusLabel(target.check_status);
        const updates = target.updates && Number.isInteger(target.updates.available) ? `${target.updates.available}` : 'Unknown';
        const button = document.createElement('button'); button.type = 'button'; button.className = 'target-card';
        button.innerHTML = `<div class="target-top"><div><div class="target-name"></div><div class="target-id"></div></div><span class="pill ${tone}">${label}</span></div><div class="target-info"><div><span>Updates</span><strong>${updates}</strong></div><div><span>Reachability</span><strong>${target.reachable === true ? 'Online' : target.reachable === false ? 'Offline' : 'Unknown'}</strong></div><div><span>Type</span><strong>${text(target.type)}</strong></div><div><span>Last check</span><strong>${date(target.last_check)}</strong></div></div>`;
        button.querySelector('.target-name').textContent = text(target.id);
        button.querySelector('.target-id').textContent = `${text(target.os)} · ${text(target.transport)}`;
        button.addEventListener('click', () => renderDetails(target)); list.appendChild(button);
      }
    }
    async function load() {
      try {
        const response = await fetch('/api/status', { cache: 'no-store' });
        const data = await response.json();
        if (!response.ok) throw new Error(data.error?.message || 'Status data could not be loaded.');
        render(data);
      } catch (error) {
        showNotice(error.message, true); setText('generated', 'Status unavailable');
        document.getElementById('targets').innerHTML = '<div class="empty">The status file is missing, empty, or invalid. The preview remains read-only.</div>';
        ['total', 'online', 'updates', 'attention'].forEach(id => setText(id, '–'));
      }
    }
    load();
  </script>
</body>
</html>
"""


class StatusHandler(BaseHTTPRequestHandler):
    server_version = "UltimateUpdaterPreview/1"

    def send_bytes(self, body, content_type, status=HTTPStatus.OK):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, payload, status=HTTPStatus.OK):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_bytes(body, "application/json; charset=utf-8", status)

    def do_GET(self):  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path == "/":
            self.send_bytes(PAGE.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/api/status":
            try:
                with self.server.status_file.open("r", encoding="utf-8") as source:
                    payload = json.load(source)
                if not isinstance(payload, dict) or not isinstance(payload.get("targets"), list):
                    raise ValueError("status JSON has no valid targets list")
            except FileNotFoundError:
                self.send_json({"error": {"code": "STATUS_NOT_FOUND", "message": "No status file is available yet."}}, HTTPStatus.NOT_FOUND)
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                self.send_json({"error": {"code": "STATUS_INVALID", "message": "The status file is missing or invalid."}}, HTTPStatus.UNPROCESSABLE_ENTITY)
            else:
                self.send_json(payload)
            return
        self.send_json({"error": {"code": "NOT_FOUND", "message": "Not found."}}, HTTPStatus.NOT_FOUND)

    def do_POST(self):  # noqa: N802 - stdlib handler API
        self.send_json({"error": {"code": "READ_ONLY", "message": "This preview is read-only."}}, HTTPStatus.METHOD_NOT_ALLOWED)

    do_PUT = do_POST
    do_PATCH = do_POST
    do_DELETE = do_POST

    def log_message(self, format_string, *args):
        # Keep the preview quiet unless the caller explicitly needs HTTP logs.
        return


def parse_args():
    parser = argparse.ArgumentParser(description="Serve the Ultimate Updater read-only status preview.")
    parser.add_argument("--status-file", type=Path, default=DEFAULT_STATUS_FILE, help="status JSON path")
    parser.add_argument("--bind", default=DEFAULT_BIND, help="bind address (default: localhost)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="HTTP port (default: 8765)")
    return parser.parse_args()


def main():
    args = parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    server = ThreadingHTTPServer((args.bind, args.port), StatusHandler)
    server.status_file = args.status_file
    print(f"Ultimate Updater read-only preview: http://{args.bind}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
