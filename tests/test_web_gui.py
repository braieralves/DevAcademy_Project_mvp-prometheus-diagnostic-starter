import importlib.util
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "runbook_gui_v2", ROOT / "mvp_UI" / "v2_runbook_web_gui.py"
)
assert SPEC is not None and SPEC.loader is not None
gui = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gui)

PAYLOAD = {
    "aksResourceId": "/subscriptions/test-subscription/resourceGroups/test-rg/providers/Microsoft.ContainerService/managedClusters/test-aks",
    "monitorWorkspaceResourceId": "/subscriptions/test-subscription/resourceGroups/test-monitor-rg/providers/Microsoft.Monitor/accounts/test-workspace",
}


class WebGuiTests(unittest.TestCase):
    def test_api_requires_explicit_authentication_consent(self):
        server = gui.ThreadingHTTPServer(("127.0.0.1", 0), gui.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.object(gui, "start_job", return_value="test-job") as start:
                for consent in (None, False, "true", True):
                    with self.subTest(consent=consent):
                        payload = dict(PAYLOAD)
                        if consent is not None:
                            payload["confirmAuthentication"] = consent
                        request = Request(
                            f"http://127.0.0.1:{server.server_port}/api/run-start",
                            data=json.dumps(payload).encode(),
                            headers={"Content-Type": "application/json"},
                        )
                        if consent is True:
                            with urlopen(request, timeout=10) as response:
                                self.assertEqual(json.load(response)["jobId"], "test-job")
                            start.assert_called_once_with(payload)
                        else:
                            with self.assertRaises(HTTPError) as error:
                                urlopen(request, timeout=10)
                            self.assertEqual(error.exception.code, 400)
                            self.assertIn("Confirm", json.load(error.exception)["error"])
                            error.exception.close()
                            start.assert_not_called()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=10)

    def test_worker_completes_without_console_confirmations(self):
        with tempfile.TemporaryDirectory(prefix="runbook-gui-test-") as directory:
            root = Path(directory)
            script = root / "collector.ps1"
            script.write_text(
                r"""param(
    [string]$AksResourceId, [string]$MonitorWorkspaceResourceId,
    [switch]$ConfirmAuthentication
)
$ErrorActionPreference = "Stop"
if (-not $ConfirmAuthentication) {
    Read-Host "Connect to AKS? [y/N]"
    throw "Console confirmation should not be needed"
}
Write-Host "Cluster connection confirmed by browser"
New-Item -ItemType Directory -Path ".\output\prom-missing-metrics-20261125-120000" -Force | Out-Null
Set-Content -Path ".\output\prom-missing-metrics-20261125-120000\report-summary.md" -Value "Fixture completed"
""",
                encoding="utf-8",
            )
            job = {"status": "queued", "executionLog": "", "result": None, "error": None}
            with (
                patch.object(gui, "PROJECT_ROOT", root),
                patch.object(gui, "RUNBOOK_SCRIPT", script),
                patch.object(gui, "OUTPUT_ROOT", root / "output"),
                patch.dict(gui.RUN_JOBS, {"test-job": job}, clear=True),
            ):
                args = gui.build_run_args(PAYLOAD)
                self.assertIn("-NonInteractive", args)
                gui.run_job("test-job", PAYLOAD)
                self.assertEqual(job["status"], "completed")
                self.assertEqual(job["result"]["returnCode"], 0)
                self.assertIn("Fixture completed", job["result"]["reportSummary"])
                self.assertIn("confirmed by browser", job["executionLog"])

    def test_worker_reports_process_start_failure(self):
        job = {"status": "queued", "executionLog": "", "result": None, "error": None}
        with (
            patch.dict(gui.RUN_JOBS, {"test-job": job}, clear=True),
            patch.object(gui.subprocess, "Popen", side_effect=FileNotFoundError("powershell")),
        ):
            gui.run_job("test-job", PAYLOAD)
        self.assertEqual(job["status"], "failed")
        self.assertIn("Could not start PowerShell", job["error"])


if __name__ == "__main__":
    unittest.main()
