#!/usr/bin/env python3
"""
Local web GUI for the Missing Prometheus Metrics runbook.
"""

from __future__ import annotations

import json
import mimetypes
import re
import subprocess
import threading
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUNBOOK_SCRIPT = PROJECT_ROOT / "03-prometheus-evidence-collection.ps1"
OUTPUT_ROOT = PROJECT_ROOT / "output"
RUN_DIR_PATTERN = re.compile(r"^prom-missing-metrics-\d{8}-\d{6}$")

RUN_JOBS: dict[str, dict] = {}
RUN_JOBS_LOCK = threading.Lock()


HTML_PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Prometheus Missing Metrics Runbook</title>
  <style>
    :root {
      --bg: #0b1220;
      --panel: #121b2f;
      --panel-2: #1a2641;
      --text: #e7edf8;
      --muted: #98a7c2;
      --accent: #4fb3ff;
      --good: #3ddc97;
      --bad: #ff6b6b;
      --border: #2b3a5c;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: Segoe UI, Inter, Arial, sans-serif;
      background: radial-gradient(80% 80% at 50% 0%, #152445, var(--bg));
      color: var(--text);
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 24px; }
    h1 { margin: 0 0 8px; font-size: 1.8rem; }
    .subtitle { color: var(--muted); margin: 0 0 20px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 12px;
    }
    .card {
      background: linear-gradient(180deg, var(--panel), var(--panel-2));
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 14px;
      box-shadow: 0 10px 30px rgba(0, 0, 0, 0.2);
    }
    label { display: block; font-size: 0.92rem; margin-bottom: 6px; color: var(--muted); }
    input {
      width: 100%;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: #0f1830;
      color: var(--text);
      padding: 10px;
    }
    input:focus { outline: 2px solid #2f7fff; outline-offset: 1px; }
    .actions { margin-top: 14px; display: flex; gap: 10px; align-items: center; }
    button {
      border: 0;
      border-radius: 10px;
      background: linear-gradient(180deg, #53bbff, #2d8eff);
      color: #001430;
      padding: 11px 16px;
      font-weight: 700;
      cursor: pointer;
    }
    button:disabled { opacity: 0.6; cursor: wait; }
    .status { color: var(--muted); font-size: 0.95rem; }
    .section-title { margin: 24px 0 10px; font-size: 1.2rem; }
    .signals { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; }
    .signal { border: 1px solid var(--border); border-radius: 10px; padding: 10px; background: #0d1630; }
    .signal .k { color: var(--muted); font-size: 0.85rem; margin-bottom: 6px; }
    .signal .v { font-size: 1.1rem; font-weight: 700; }
    .pill {
      display: inline-flex;
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 0.85rem;
      font-weight: 700;
      margin-right: 8px;
    }
    .ok { background: rgba(61, 220, 151, 0.16); color: var(--good); border: 1px solid rgba(61, 220, 151, 0.3); }
    .fail { background: rgba(255, 107, 107, 0.16); color: var(--bad); border: 1px solid rgba(255, 107, 107, 0.3); }
    pre {
      margin: 0;
      white-space: pre-wrap;
      word-break: break-word;
      font-family: Consolas, "Courier New", monospace;
      font-size: 0.9rem;
      color: #dfe8ff;
    }
    .log-view {
      max-height: 360px;
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 10px;
      background: #0d1630;
      padding: 10px;
    }
    .two-col {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
    }
    @media (max-width: 960px) { .two-col { grid-template-columns: 1fr; } }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    table { width: 100%; border-collapse: collapse; }
    th, td { text-align: left; padding: 8px; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); font-weight: 600; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Prometheus Runbook Dashboard</h1>
    <p class="subtitle">Run the diagnostic script and review a cleaner analysis view with one click.</p>

    <div class="card">
      <div class="grid">
        <div>
          <label for="aksResourceId">AKS Resource ID</label>
          <input id="aksResourceId" placeholder="/subscriptions/&lt;sub-id&gt;/resourceGroups/&lt;rg&gt;/providers/Microsoft.ContainerService/managedClusters/&lt;aks-name&gt;" />
        </div>
        <div>
          <label for="monitorWorkspaceResourceId">Azure Monitor Workspace Resource ID</label>
          <input id="monitorWorkspaceResourceId" placeholder="/subscriptions/&lt;sub-id&gt;/resourceGroups/&lt;rg&gt;/providers/Microsoft.Monitor/accounts/&lt;workspace-name&gt;" />
        </div>
        <div>
          <label for="expectedMetricName">Expected Metric Name (optional)</label>
          <input id="expectedMetricName" placeholder="http_requests_total" />
        </div>
      </div>
      <div class="actions">
        <button id="runBtn">Run Diagnostic</button>
        <span class="status" id="status">Ready.</span>
      </div>
    </div>

    <div id="results" style="display:none;">
      <h2 class="section-title">Verbose (live output)</h2>
      <div class="card">
        <div class="log-view"><pre id="executionLog"></pre></div>
      </div>

      <h2 class="section-title">Run Summary</h2>
      <div class="card">
        <div id="summaryHeader"></div>
        <div class="signals" id="signals"></div>
      </div>

      <div style="margin-top:12px;" class="card">
        <h3 style="margin-top:0;">report-summary.md</h3>
        <pre id="reportSummary"></pre>
      </div>

      <h2 class="section-title">Artifacts</h2>
      <div class="card">
        <table>
          <thead><tr><th>File</th><th>Size (KB)</th></tr></thead>
          <tbody id="artifactRows"></tbody>
        </table>
      </div>
    </div>
  </div>

  <script>
    const byId = (id) => document.getElementById(id);
    const runBtn = byId("runBtn");
    const statusEl = byId("status");
    const resultsEl = byId("results");
    const executionLogEl = byId("executionLog");

    function setStatus(text) { statusEl.textContent = text; }

    function collectInput() {
      return {
        aksResourceId: byId("aksResourceId").value.trim(),
        monitorWorkspaceResourceId: byId("monitorWorkspaceResourceId").value.trim(),
        expectedMetricName: byId("expectedMetricName").value.trim(),
      };
    }

    function renderSignals(signals) {
      const container = byId("signals");
      container.innerHTML = "";
      if (!signals || Object.keys(signals).length === 0) {
        container.innerHTML = "<div class='signal'><div class='k'>Signals</div><div class='v'>No parsed signals</div></div>";
        return;
      }
      Object.entries(signals).forEach(([key, value]) => {
        const div = document.createElement("div");
        div.className = "signal";
        div.innerHTML = `<div class="k">${key}</div><div class="v">${value}</div>`;
        container.appendChild(div);
      });
    }

    function renderArtifacts(runName, artifacts) {
      const tbody = byId("artifactRows");
      tbody.innerHTML = "";
      if (!artifacts || artifacts.length === 0) {
        tbody.innerHTML = "<tr><td colspan='2'>No artifacts found.</td></tr>";
        return;
      }
      artifacts.forEach((item) => {
        const tr = document.createElement("tr");
        const href = `/api/artifact?run=${encodeURIComponent(runName)}&file=${encodeURIComponent(item.name)}`;
        tr.innerHTML = `<td><a href="${href}" target="_blank" rel="noopener">${item.name}</a></td><td>${item.sizeKb}</td>`;
        tbody.appendChild(tr);
      });
    }

    function sleep(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    }

    async function pollJob(jobId) {
      while (true) {
        const res = await fetch(`/api/run-status?jobId=${encodeURIComponent(jobId)}`);
        const data = await res.json();
        if (!res.ok) {
          throw new Error(data.error || "Could not read run status.");
        }

        executionLogEl.textContent = data.executionLog || "";
        executionLogEl.parentElement.scrollTop = executionLogEl.parentElement.scrollHeight;

        if (data.status === "queued" || data.status === "running") {
          setStatus("Running diagnostic. Streaming live output...");
          await sleep(1000);
          continue;
        }

        if (data.status === "failed") {
          throw new Error(data.error || "Run failed.");
        }

        return data.result;
      }
    }

    async function runDiagnostic() {
      const payload = collectInput();
      const required = ["aksResourceId", "monitorWorkspaceResourceId"];
      const missing = required.filter((k) => !payload[k]);
      if (missing.length > 0) {
        setStatus("Fill all required fields.");
        return;
      }

      if (!window.confirm(`Sign in to Azure and connect to AKS ${payload.aksResourceId}, and update the local kubeconfig (overwriting an existing entry)? Complete authentication in any sign-in window that opens.`)) {
        setStatus("Authentication cancelled.");
        return;
      }
      payload.confirmAuthentication = true;

      runBtn.disabled = true;
      setStatus("Starting diagnostic...");
      resultsEl.style.display = "block";
      byId("summaryHeader").innerHTML = "";
      byId("reportSummary").textContent = "";
      executionLogEl.textContent = "";
      byId("artifactRows").innerHTML = "";
      byId("signals").innerHTML = "";

      try {
        const startRes = await fetch("/api/run-start", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        const startData = await startRes.json();
        if (!startRes.ok || !startData.success) {
          throw new Error(startData.error || "Could not start diagnostic.");
        }

        const data = await pollJob(startData.jobId);
        const summaryHeader = byId("summaryHeader");
        const cls = data.returnCode === 0 ? "ok" : "fail";
        const txt = data.returnCode === 0 ? "Run completed" : "Run finished with errors";
        summaryHeader.innerHTML = `<span class="pill ${cls}">${txt}</span><span>${data.outputDir}</span>`;

        byId("reportSummary").textContent = data.reportSummary || "No report-summary.md found.";
        renderSignals(data.signals || {});
        renderArtifacts(data.runName, data.artifacts || []);
        setStatus("Done.");
      } catch (err) {
        setStatus(err.message);
      } finally {
        runBtn.disabled = false;
      }
    }

    runBtn.addEventListener("click", runDiagnostic);
  </script>
</body>
</html>
"""


def json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    content = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(content)))
    handler.end_headers()
    handler.wfile.write(content)


def parse_signals(report_summary: str) -> dict[str, str]:
    lines = report_summary.splitlines()
    in_signals = False
    result: dict[str, str] = {}
    for line in lines:
        if line.strip() == "## Initial signals":
            in_signals = True
            continue
        if in_signals and line.startswith("## "):
            break
        if in_signals and line.strip().startswith("- ") and ":" in line:
            item = line.strip()[2:]
            key, value = item.split(":", 1)
            result[key.strip()] = value.strip()
    return result


def list_run_directories() -> set[str]:
    if not OUTPUT_ROOT.exists():
        return set()
    return {p.name for p in OUTPUT_ROOT.iterdir() if p.is_dir() and RUN_DIR_PATTERN.match(p.name)}


def find_new_run_directory(before: set[str]) -> Path | None:
    if not OUTPUT_ROOT.exists():
        return None
    candidates = [p for p in OUTPUT_ROOT.iterdir() if p.is_dir() and RUN_DIR_PATTERN.match(p.name) and p.name not in before]
    if candidates:
        return max(candidates, key=lambda p: p.stat().st_mtime)
    # Fallback in case run folder already existed for any reason.
    all_candidates = [p for p in OUTPUT_ROOT.iterdir() if p.is_dir() and RUN_DIR_PATTERN.match(p.name)]
    if not all_candidates:
        return None
    return max(all_candidates, key=lambda p: p.stat().st_mtime)


def build_run_args(payload: dict) -> list[str]:
    args = [
        "powershell",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(RUNBOOK_SCRIPT),
        "-ConfirmAuthentication",
        "-AksResourceId",
        payload["aksResourceId"].strip(),
        "-MonitorWorkspaceResourceId",
        payload["monitorWorkspaceResourceId"].strip(),
    ]
    expected_metric = payload.get("expectedMetricName", "").strip()
    if expected_metric:
        args.extend(["-ExpectedMetricName", expected_metric])
    return args


def assemble_result(return_code: int, output_dir: Path | None, execution_log: str) -> dict:
    if output_dir is None:
        return {
            "success": False,
            "error": "Script finished, but no output folder was found under ./output.",
            "returnCode": return_code,
            "executionLog": execution_log,
        }

    report_path = output_dir / "report-summary.md"
    report_summary = report_path.read_text(encoding="utf-8") if report_path.exists() else ""
    artifacts = []
    for artifact in sorted(output_dir.iterdir()):
        if artifact.is_file():
            artifacts.append({"name": artifact.name, "sizeKb": round(artifact.stat().st_size / 1024, 2)})

    return {
        "success": True,
        "returnCode": return_code,
        "runName": output_dir.name,
        "outputDir": str(output_dir),
        "reportSummary": report_summary,
        "signals": parse_signals(report_summary),
        "artifacts": artifacts,
        "executionLog": execution_log,
    }


def run_job(job_id: str, payload: dict) -> None:
    before = list_run_directories()
    args = build_run_args(payload)
    log_lines: list[str] = []

    try:
        proc = subprocess.Popen(
            args,
            cwd=str(PROJECT_ROOT),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
    except OSError as exc:
        with RUN_JOBS_LOCK:
            RUN_JOBS[job_id]["status"] = "failed"
            RUN_JOBS[job_id]["error"] = f"Could not start PowerShell: {exc}"
        return

    with RUN_JOBS_LOCK:
        RUN_JOBS[job_id]["status"] = "running"

    if proc.stdout is not None:
        with proc.stdout:
            for line in proc.stdout:
                log_lines.append(line)
                with RUN_JOBS_LOCK:
                    RUN_JOBS[job_id]["executionLog"] = "".join(log_lines)

    return_code = proc.wait()
    execution_log = "".join(log_lines).strip()
    output_dir = find_new_run_directory(before)
    result = assemble_result(return_code, output_dir, execution_log)

    with RUN_JOBS_LOCK:
        RUN_JOBS[job_id]["executionLog"] = execution_log
        RUN_JOBS[job_id]["result"] = result
        RUN_JOBS[job_id]["status"] = "completed" if result.get("success") else "failed"
        if result.get("success") is False:
            RUN_JOBS[job_id]["error"] = result.get("error", "Run failed.")


def start_job(payload: dict) -> str:
    job_id = str(uuid.uuid4())
    with RUN_JOBS_LOCK:
        RUN_JOBS[job_id] = {
            "status": "queued",
            "executionLog": "",
            "result": None,
            "error": None,
        }
    thread = threading.Thread(target=run_job, args=(job_id, payload), daemon=True)
    thread.start()
    return job_id


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = HTML_PAGE.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/api/run-status":
            query = parse_qs(parsed.query)
            job_id = (query.get("jobId") or [""])[0]
            with RUN_JOBS_LOCK:
                job = RUN_JOBS.get(job_id)
            if not job:
                json_response(self, HTTPStatus.NOT_FOUND, {"error": "Job not found."})
                return
            payload = {
                "status": job["status"],
                "executionLog": job.get("executionLog", ""),
                "result": job.get("result"),
                "error": job.get("error"),
            }
            json_response(self, HTTPStatus.OK, payload)
            return

        if parsed.path == "/api/artifact":
            query = parse_qs(parsed.query)
            run_name = (query.get("run") or [""])[0]
            file_name = (query.get("file") or [""])[0]
            if not RUN_DIR_PATTERN.match(run_name):
                json_response(self, HTTPStatus.BAD_REQUEST, {"error": "Invalid run folder."})
                return
            if not file_name or Path(file_name).name != file_name:
                json_response(self, HTTPStatus.BAD_REQUEST, {"error": "Invalid file name."})
                return

            artifact_path = OUTPUT_ROOT / run_name / file_name
            if not artifact_path.exists() or not artifact_path.is_file():
                json_response(self, HTTPStatus.NOT_FOUND, {"error": "Artifact not found."})
                return

            content = artifact_path.read_bytes()
            mime, _ = mimetypes.guess_type(str(artifact_path))
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mime or "application/octet-stream")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        json_response(self, HTTPStatus.NOT_FOUND, {"error": "Not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/run-start":
            json_response(self, HTTPStatus.NOT_FOUND, {"error": "Not found"})
            return

        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            json_response(self, HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON body."})
            return

        required = [
            "aksResourceId",
            "monitorWorkspaceResourceId",
        ]
        missing = [field for field in required if not str(payload.get(field, "")).strip()]
        if missing:
            json_response(self, HTTPStatus.BAD_REQUEST, {"error": f"Missing required fields: {', '.join(missing)}"})
            return

        if payload.get("confirmAuthentication") is not True:
            json_response(self, HTTPStatus.BAD_REQUEST, {"error": "Confirm Azure sign-in and AKS kubeconfig update before starting."})
            return

        if not RUNBOOK_SCRIPT.exists():
            json_response(self, HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"Runbook script not found: {RUNBOOK_SCRIPT.name}"})
            return

        job_id = start_job(payload)
        json_response(self, HTTPStatus.OK, {"success": True, "jobId": job_id})

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def main() -> None:
    host = "127.0.0.1"
    port = 8750
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Runbook GUI available at http://{host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
