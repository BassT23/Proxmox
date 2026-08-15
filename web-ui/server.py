#!/usr/bin/env python3
"""Small standard-library web UI for status and session-independent actions."""

import argparse
import json
import os
import re
import subprocess
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


DEFAULT_STATUS_FILE = Path("/etc/ultimate-updater/status.json")
DEFAULT_CLI = Path("/usr/local/sbin/ultimate-updater")
DEFAULT_JOB_RUNNER = Path("/etc/ultimate-updater/job-runner.sh")
DEFAULT_JOBS_DIR = Path("/var/lib/ultimate-updater/jobs")
DEFAULT_BIND = "127.0.0.1"
DEFAULT_PORT = 8765
TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
JOB_RE = re.compile(r"^ultimate-updater-update-[A-Za-z0-9_.-]+$")


PAGE = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark"><title>Ultimate Updater</title>
  <style>
    :root { color-scheme:dark; --bg:#0b1020; --panel:#151d34e8; --strong:#19233f; --text:#edf3ff; --muted:#91a0bd; --line:#94a3b82e; --accent:#73a7ff; --good:#55d39a; --warn:#f7c66b; --bad:#ff7e8b; font-family:Inter,ui-sans-serif,system-ui,sans-serif; }
    * { box-sizing:border-box } body { margin:0; min-height:100vh; color:var(--text); background:radial-gradient(circle at top right,#1e3567 0,var(--bg) 42rem) }
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
    .details,.jobs { border-radius:16px; padding:20px; margin-top:18px } .details h3 { margin:0 0 15px } .error-text { color:var(--bad); white-space:pre-wrap; overflow-wrap:anywhere }
    .job { display:grid; grid-template-columns:1.6fr 1fr .9fr auto; gap:10px; align-items:center; padding:11px 0; border-bottom:1px solid var(--line); font-size:.82rem } .job:last-child { border-bottom:0 } .job code { overflow-wrap:anywhere } .job small { color:var(--muted) } .log { max-height:220px; overflow:auto; white-space:pre-wrap; background:#00000045; border-radius:8px; padding:12px; margin-top:12px; color:#cbd5e1; font: .75rem ui-monospace,monospace }
    .empty { border:1px dashed var(--line); border-radius:16px; padding:30px; text-align:center; color:var(--muted) } footer { font-size:.75rem; margin-top:28px }
    @media (max-width:720px) { main { width:calc(100% - 22px); padding-top:25px } header { display:block } .meta { text-align:left; margin-top:15px } .summary { grid-template-columns:repeat(2,1fr) } .job { grid-template-columns:1fr 1fr } .job button { grid-column:span 2; width:100% } }
  </style>
</head>
<body><main>
  <header><div><div class="eyebrow">Universal Systems · Preview</div><h1>Ultimate Updater</h1><p class="subtitle">Start checks and session-independent update jobs. The core owns execution; this page only observes it.</p></div><div class="meta" id="generated">Loading status…</div></header>
  <div id="notice" hidden></div>
  <section class="summary"><div class="metric"><strong id="total">–</strong><span>known targets</span></div><div class="metric"><strong id="online">–</strong><span>reachable</span></div><div class="metric"><strong id="updates">–</strong><span>available updates</span></div><div class="metric"><strong id="attention">–</strong><span>needs attention</span></div></section>
  <section><div class="section-title"><h2>Systems</h2><span class="hint">Checks and updates use the existing CLI</span></div><div id="targets" class="targets"></div></section>
  <section id="details" class="details" hidden></section><section id="jobs" class="jobs" hidden></section>
  <footer>Local action preview · status: <code>/etc/ultimate-updater/status.json</code> · jobs: <code>/var/lib/ultimate-updater/jobs</code></footer>
  <script>
    const labels={ok:['Healthy','good'],updates_available:['Updates available','warn'],offline:['Offline','bad'],unsupported:['Unsupported','neutral'],not_checked:['Not checked','neutral'],error:['Error','bad']};
    const text=(v,f='Unknown')=>v===null||v===undefined||v===''?f:String(v); const esc=v=>text(v,'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const date=v=>{if(!v)return'Unknown';const d=new Date(v);return Number.isNaN(d.getTime())?String(v):d.toLocaleString()}; const statusLabel=v=>labels[v]||['Unknown','neutral']; const set=(id,v)=>document.getElementById(id).textContent=v;
    let currentStatus={targets:[]}, jobs=[], pollTimer;
    function notice(message,error=false){const n=document.getElementById('notice');n.hidden=false;n.textContent=message;n.className=error?'notice error':'notice'}
    function running(target){return jobs.some(j=>j.target===target&&j.state==='running')}
    function renderDetails(t){const n=document.getElementById('details'),[label,tone]=statusLabel(t.check_status),e=t.error?`${text(t.error.code,'')}${t.error.message?': '+t.error.message:''}`:'None';n.hidden=false;n.innerHTML=`<h3>${esc(t.id)}</h3><div class="detail-grid"><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Transport</span><strong>${esc(t.transport)}</strong></div><div><span>Operating system</span><strong>${esc(t.os)}</strong></div><div><span>Updater</span><strong>${esc(t.updater)}</strong></div><div><span>Check status</span><strong class="pill ${tone}">${label}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div><div><span>Reboot required</span><strong>${t.reboot_required===null?'Unknown':t.reboot_required?'Yes':'No'}</strong></div><div><span>Last update</span><strong>${esc(t.last_update&&t.last_update.status)}</strong></div><div><span>Error</span><strong class="error-text">${esc(e)}</strong></div></div>`;n.scrollIntoView({behavior:'smooth',block:'nearest'})}
    async function action(path,update=false){if(update&&!confirm(`Start update for "${path.split('/').pop()}"?`))return;try{const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Action failed');notice(d.message||'Action accepted.');await loadStatus();await loadJobs()}catch(e){notice(e.message,true)}}
    function render(data){currentStatus=data;const ts=Array.isArray(data.targets)?data.targets:[];set('total',ts.length);set('online',ts.filter(t=>t.reachable===true).length);set('updates',ts.map(t=>t.updates&&t.updates.available).filter(Number.isInteger).reduce((a,v)=>a+v,0));set('attention',ts.filter(t=>t.check_status!=='ok').length);set('generated',`Schema ${text(data.schema_version)} · generated ${date(data.generated_at)}`);const list=document.getElementById('targets');list.replaceChildren();if(!ts.length){list.innerHTML='<div class="empty">No target status is available yet. Run a check to populate the view.</div>';return}for(const t of ts){const [label,tone]=statusLabel(t.check_status),u=t.updates&&Number.isInteger(t.updates.available)?t.updates.available:'Unknown';const card=document.createElement('article');card.className='target-card';card.innerHTML=`<div class="target-top"><div><div class="target-name">${esc(t.id)}</div><div class="target-id">${esc(t.os)} · ${esc(t.transport)}</div></div><span class="pill ${tone}">${label}</span></div><div class="target-info"><div><span>Updates</span><strong>${u}</strong></div><div><span>Reachability</span><strong>${t.reachable===true?'Online':t.reachable===false?'Offline':'Unknown'}</strong></div><div><span>Type</span><strong>${esc(t.type)}</strong></div><div><span>Last check</span><strong>${esc(date(t.last_check))}</strong></div></div><div class="actions"><button class="check">Check</button><button class="primary update">${running(t.id)?'Update running':'Start update'}</button></div>`;card.addEventListener('click',e=>{if(!e.target.closest('button'))renderDetails(t)});card.querySelector('.check').addEventListener('click',e=>{e.stopPropagation();action(`/api/check/${encodeURIComponent(t.id)}`)});const b=card.querySelector('.update');b.disabled=running(t.id)||!TARGET_UPDATEABLE(t);b.addEventListener('click',e=>{e.stopPropagation();action(`/api/update/${encodeURIComponent(t.id)}`,true)});list.appendChild(card)}}
    function TARGET_UPDATEABLE(t){return ['ok','updates_available'].includes(t.check_status)}
    function renderJobs(){const n=document.getElementById('jobs');if(!jobs.length){n.hidden=true;return}n.hidden=false;n.innerHTML='<div class="section-title"><h2>Update jobs</h2><span class="hint">Server-side state · safe across browser/device changes</span></div>'+jobs.map(j=>`<div class="job"><code>${esc(j.unit)}</code><span>${esc(j.target)}</span><span class="pill ${j.state==='completed'?'good':j.state==='failed'||j.state==='interrupted'?'bad':'warn'}">${esc(j.state)}</span><button data-job="${esc(j.unit)}">Show log</button><div class="log" id="log-${esc(j.unit)}" hidden></div></div>`).join('');n.querySelectorAll('button[data-job]').forEach(b=>b.addEventListener('click',async()=>{try{const r=await fetch(`/api/jobs/${encodeURIComponent(b.dataset.job)}/log`),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Log unavailable');const node=document.getElementById(`log-${b.dataset.job}`);node.hidden=false;node.textContent=d.log||'(no journal output)'}catch(e){notice(e.message,true)}}))}
    async function loadStatus(){try{const r=await fetch('/api/status',{cache:'no-store'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Status unavailable');render(d)}catch(e){notice(e.message,true);set('generated','Status unavailable');document.getElementById('targets').innerHTML='<div class="empty">The status file is missing or invalid.</div>'}}
    async function loadJobs(){try{const r=await fetch('/api/jobs',{cache:'no-store'}),d=await r.json();if(!r.ok)throw new Error(d.error?.message||'Jobs unavailable');jobs=Array.isArray(d.jobs)?d.jobs:[];renderJobs();clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,jobs.some(j=>j.state==='running')?2000:10000);render(currentStatus)}catch(e){clearTimeout(pollTimer);pollTimer=setTimeout(loadJobs,10000)}}
    loadStatus();loadJobs();
  </script>
</main></body></html>"""


def error_payload(code, message):
    return {"error": {"code": code, "message": message}}


def parse_state_line(line):
    fields = line.rstrip("\n").split("\t")
    if len(fields) != 6:
        return None
    unit, target, state, started, finished, exit_code = fields
    return {"unit": unit, "target": target, "state": state,
            "started_at": started or None, "finished_at": finished or None,
            "exit_code": int(exit_code) if exit_code.lstrip("-").isdigit() else None}


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
        if length:
            self.rfile.read(length)

    def run_command(self, args, timeout=300):
        return subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=timeout, check=False,
                              env={**os.environ, "UU_JOB_STATE_DIR": str(self.server.jobs_dir)})

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

    def do_GET(self):  # noqa: N802 - stdlib handler API
        path = urlsplit(self.path).path
        if path == "/":
            self.send_bytes(PAGE.encode(), "text/html; charset=utf-8")
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
                if not self.valid_job(unit):
                    raise ValueError
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
            self.read_body()
        except OverflowError as error:
            self.send_json(error_payload("REQUEST_TOO_LARGE", str(error)), HTTPStatus.REQUEST_ENTITY_TOO_LARGE)
            return
        except ValueError as error:
            self.send_json(error_payload("BAD_REQUEST", str(error)), HTTPStatus.BAD_REQUEST)
            return
        parts = [unquote(part) for part in urlsplit(self.path).path.split("/") if part]
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
            result = self.run_command([str(self.server.cli), "check", target])
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
        self.do_POST()

    do_PATCH = do_PUT
    do_DELETE = do_PUT

    def log_message(self, format_string, *args):
        return


def parse_args():
    parser = argparse.ArgumentParser(description="Serve the Ultimate Updater status and action preview.")
    parser.add_argument("--status-file", type=Path, default=DEFAULT_STATUS_FILE)
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
