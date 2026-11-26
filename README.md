# MVP Starter — Missing Prometheus Metrics Diagnostic

Initial package (week 1) of the Capstone for the topic:
**Accelerating Troubleshooting for Missing Prometheus Metrics in Azure Monitor**.

## What is included

1. `01-operational-prompt-prometheus.txt`  
   Standard prompt for technical analysis and diagnostic closure.

2. `02-operational-checklist-prometheus.txt`  
   Reusable checklist to ensure consistent evidence collection.

3. `03-prometheus-evidence-collection.ps1`  
   Evidence collector for linked DCR/DCE resources, AMPLS associations, ama-metrics health and logs, scrape configuration, and workspace ingestion limits.

4. [mvp_UI](./mvp_UI/) contains web GUI versions 1 and 2. Start either with `python .\mvp_UI\v1_runbook_web_gui.py` or `python .\mvp_UI\v2_runbook_web_gui.py`, then open `http://127.0.0.1:8750`. Run only one version at a time; both use the repository-root runbook and output directory.

## MVP objective

Standardize troubleshooting to reduce variation across engineers and accelerate identification of the **failure domain**:
- target discovery
- scraping
- ama-metrics
- DCR/DCE
- connectivity/DNS/AMPLS
- ingestion/publication
- query/expectation

## Prerequisites

- PowerShell 5.1+ ou 7+
- Azure CLI (`az`) installed; the script prompts for interactive sign-in
- `kubectl` installed and on PATH (required)
- `kubelogin` on PATH when required by a Microsoft Entra-enabled AKS cluster
- Read permissions on the workspace and linked DCR/DCE resources, including resources in other resource groups or subscriptions
- Azure Monitor metrics read access on the workspace
- Permission to retrieve AKS user credentials, list nodes/pods, read the four scrape ConfigMaps and Azure monitor CRDs/custom resources, read pod logs, and exec into a collector container

## Quick run

```powershell
powershell -ExecutionPolicy Bypass -File .\03-prometheus-evidence-collection.ps1 `
  -AksResourceId "/subscriptions/<subscription-id>/resourceGroups/<aks-rg>/providers/Microsoft.ContainerService/managedClusters/<aks-name>" `
  -MonitorWorkspaceResourceId "/subscriptions/<subscription-id>/resourceGroups/<monitor-rg>/providers/Microsoft.Monitor/accounts/<azure-monitor-workspace-name>" `
  -ExpectedMetricName "<optional-metric-name>"
```

The script derives the subscription, resource group and name from the resource IDs. The Azure CLI subscription is set from the AKS resource ID; the workspace is queried by its full resource ID, so it may be in another subscription you can read.

### Authentication

1. Confirm Azure sign-in when prompted, then complete standard `az login` authentication using an account with access to the requested subscription. The script does not force device-code authentication.
2. The script selects that subscription as the active Azure CLI subscription.
3. Confirm the cluster connection. This retrieves AKS user credentials and updates the local kubeconfig (including overwriting an existing entry). Every Kubernetes query explicitly selects the requested cluster context.
4. Complete any sign-in requested by the cluster credential plugin. Before collecting resource evidence, the script verifies access with `kubectl get nodes` and a 60-second request timeout.

Declining either confirmation stops the script. Failed Azure authentication, subscription selection, credential retrieval, or cluster access also stops it. Missing `kubectl` is a blocking error, not a skipped check; install it and, for Microsoft Entra clusters, `kubelogin` (for example, using `az aks install-cli`), ensure the tools are on PATH, and rerun.

Authentication and mandatory cluster/pod access failures stop the script. Other evidence failures are recorded in the report and `collection-issues.txt`; the script exits nonzero after writing an **Incomplete** summary. Optional ConfigMaps and CRDs that genuinely don't exist are reported as absent, not as command failures. Each Kubernetes request has a 60-second request timeout. Run from an interactive terminal; do not enter passwords or tokens into script parameters.

The v2 web GUI asks for Azure sign-in and AKS connection consent in a browser confirmation dialog before starting. It passes `-ConfirmAuthentication` to the collector and disables PowerShell console input so hidden `Read-Host` prompts cannot stall the worker. This switch only confirms the two consent prompts; Azure sign-in and cluster-access verification still run. Complete authentication in the Azure sign-in window, not in the server terminal. Restart the GUI server after updating it. Unexpected PowerShell console prompts fail instead of waiting for terminal input.

### Authentication checks

Run `powershell -NoProfile -File .\tests\authentication.tests.ps1` to exercise authentication and evidence collection with local test doubles. Cases include cross-resource-group/subscription discovery, paginated associations, AMPLS links versus unrelated workspace defaults, missing resources, access failures, per-dimension quotas, zero/missing samples, and the 100% threshold. These checks do not contact Azure or modify kubeconfig. The same file can be run with PowerShell 7.

Run `python -B -m unittest discover -s tests -p "test_*.py"` for the v2 GUI confirmation and worker regression checks. These use a local PowerShell fixture, not Azure.

## Output

The script generates an `output\prom-missing-metrics-<timestamp>` folder. Every evidence file is plain text, and **`evidence-report.txt`** combines the summary and all other files into a single document that anyone can read. `report-summary.md` is the short summary shown by the web GUI.

At the end of every collection the script also writes a **technical report** that explains the environment, the issues found and how to troubleshoot them, with links to the official Microsoft documentation. Open `technical-report.html` in a browser: the Azure Monitor workspace ingestion charts are embedded in it as images. `technical-report.txt` has the same content as text. The report is built from the collected evidence: findings are rated Critical, Warning or Informational, each with its evidence, why it matters, and suggested steps. Missing evidence is reported as Unknown, never as healthy. Absence of a finding is not proof of health.

| Artifact | Content |
| --- | --- |
| `technical-report.html`, `technical-report.txt` | Executive summary, environment (AKS, workspace, DCR/DCE, private link, collector pods, scrape configuration), ingestion charts, findings with troubleshooting steps, recommended troubleshooting order and official Microsoft documentation. |
| `ingestion-*.png` | One chart image per ingestion metric (usage over time and utilization against the 100% limit). The same images are embedded in `technical-report.html`. |
| `evidence-report.txt` | Everything collected in one text file: technical report, summary, charts, DCR/DCE responses, logs, in-container search results, ConfigMaps and monitors, with a table of contents. Images are referenced, not embedded. |
| `04-dcr-list.txt`, `05-dce-list.txt` | Full resource responses (JSON text) discovered by **resource ID** from AKS associations, DCR endpoint references, and workspace default ingestion settings. This includes Azure-managed resource groups; it is not limited to the workspace resource group. Each file has an explicit discovery status and a `resources` array. Workspace defaults are distinguished from cluster-linked resources. |
| `06-dcr-associations-aks.txt` | All pages of associations on the AKS resource. |
| `ampls-association.txt` | `Associated`, `NotAssociated`, or `Unknown`, verification completeness, full AMPLS ARM IDs, and the DCE/scoped-resource evidence. Uses the cluster's DCEs, including those used by linked DCR destination workspaces. Merely having an AMPLS in a subscription or on unrelated workspace defaults does not establish a cluster association. This is not a DNS/VNet connectivity test. |
| `workspace-network.txt` | The requested Azure Monitor workspace's public network access setting: Enabled, Disabled, another service-provided setting, or Unknown. No workspace JSON payload is saved. |
| `ingestion-status.txt` | Actual workspace **Events per minute** and **Active time series** limits, usage, utilization percentages and peak utilization, whether the limit was reached (`>=100%`) or exceeded (`>100%`) in the observed samples, and **line charts** of usage and utilization over the last 60 minutes. |
| `ama-metrics-status.txt` | Only ama-metrics pod/container status: phase, Ready, restart counts, current state, and previous termination reasons. No full kube-system pod dump is saved. |
| `*-prometheus-collector.txt`, `*-prometheus-collector-previous.txt` | Output of `kubectl logs <pod> -c prometheus-collector -n kube-system` for each ama-metrics pod, and the `--previous` logs when restarts are reported. |
| `*-container-search.txt` | Search for errors, warnings, failures and similar messages inside each running Linux `prometheus-collector` container. The script runs `kubectl exec -i <pod> -c prometheus-collector -n kube-system -- /bin/bash` and sends the search commands to that shell (`-t` is omitted because a script has no terminal). It searches log and message files only (`*.log`, `*.txt`, `mdsd.*`, `*.err`, `*.warn`, `*.info`, `*.qos` under `/MetricsExtensionConsoleDebugLog.log`, `/opt/microsoft`, `/etc/prometheus`, `/tmp`), showing the last 100 matches per file. Secret-, token-, certificate- and key-like file names are skipped. |
| `ama-metrics-errors-warnings.txt` | Error/warning/fail/fatal/exception/throttling matches from the retrieved logs and the in-container search, not an automated proof of health. |
| `collector-files.txt`, `collector-file-errors-warnings.txt` | Read-only config and diagnostic excerpts from one running Linux `prometheus-collector`. Looks for YAML/JSON/TOML/conf and extensionless Prometheus/config/settings files under `/etc/config/settings`, `/opt/microsoft/otelcollector`, and `/etc/prometheus` (depth 4). Includes MetricsExtension and mdsd diagnostic logs when present. File sizes are printed; config content is capped at 1 MiB per file, diagnostic logs at 5,000 lines. Missing paths and unsupported Windows-only scenarios are explicit. |
| `configmaps-status.txt`, `ama-metrics-*.txt` | Only the four documented ConfigMaps listed below, with readable YAML text when present and explicit absent/error status otherwise. |
| `monitors-status.txt`, `*.azmonitoring.coreos.com*.txt` | Azure PodMonitor/ServiceMonitor CRD definitions and custom-resource contents from all namespaces as readable YAML text. Missing CRDs are explicit; OSS `monitoring.coreos.com` resources are not collected. |
| `collection-issues.txt`, `report-summary.md` | Collection completeness, missing evidence, initial findings and evidence references. |

No separate account-show, aks-show, monitor-workspace, AKS authentication, get-credentials, or full kube-system-pods artifacts are produced. Authentication still runs; credentials are not exported as evidence. Existing evidence folders from earlier versions are not modified.

### Scrape configuration scope

Only these optional ConfigMaps in `kube-system` are queried:

- `ama-metrics-settings-configmap`
- `ama-metrics-prometheus-config`
- `ama-metrics-prometheus-config-node`
- `ama-metrics-prometheus-config-node-windows`

See Microsoft's [settings ConfigMap](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-configuration), [custom scrape ConfigMaps](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-configmap), and [PodMonitor/ServiceMonitor CRDs](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-crd) documentation.

### Ingestion interpretation

Metrics cover the **requested workspace**, not just the cluster, over the last 60 minutes UTC at one-minute intervals. Queries omit dimension filters because Azure rejects explicit filtering on the hidden `StampColor` dimension; any series metadata returned by the API is preserved. Counts and actual limits use the supported Maximum aggregation; the official utilization metrics use their supported Average aggregation. Peak utilization is the highest observed one-minute average, not instantaneous utilization. Latest usage, limit and percentage each include their own measurement timestamp; a recent quota change is not hidden by substituting a default limit.

An exceedance means a measured utilization was above 100%; exactly 100% is reported as reached, not exceeded. "No" means no exceedance observed in the available samples; it cannot prove the absence of spikes or missing data. Missing metrics, permissions, or resource reads yield **Unknown**, not zero utilization or "not associated." Null samples are ignored; real zero values are retained. Historical limits, sample counts, timestamps and percentages remain available in the evidence. See [workspace ingestion monitoring](https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-monitor-ingest-limits) and [supported workspace metrics](https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-monitor-accounts-metrics).

### Evidence handling

Collection does not change scrape settings, restart pods, or enable debug mode. The in-container snapshot excludes Secret mounts, service-account tokens, environment variables, certificate directories and private-key files. ConfigMaps, scrape configs and logs can still contain inline credentials or sensitive target names: review and redact evidence before sharing it. Keep generated output local and out of source control.

## Recommended flow (1 week)

1. Run the script on 3-5 representative cases.
2. Complete the checklist for each case.
3. Use the prompt to generate a consistent conclusion per case.
4. Consolidate failure-domain patterns to feed the capstone experiment.
