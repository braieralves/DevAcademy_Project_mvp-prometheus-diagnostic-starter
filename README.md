# MVP Starter — Missing Prometheus Metrics Diagnostic

Initial package (week 1) of the Capstone for the topic:
**Accelerating Troubleshooting for Missing Prometheus Metrics in Azure Monitor**.

## What is included

1. `01-operational-prompt-prometheus.txt`  
   Standard prompt for technical analysis and diagnostic closure.

2. `02-operational-checklist-prometheus.txt`  
   Reusable checklist to ensure consistent evidence collection.

3. `03-prometheus-evidence-collection.ps1`  
   Lightweight script to collect environment data (AKS, DCR/DCE, ama-metrics, DNS, and basic signals).

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
- Read permissions on AKS and Monitoring resources
- Permission to retrieve AKS user credentials and Kubernetes read access for cluster evidence

## Quick run

```powershell
powershell -ExecutionPolicy Bypass -File .\03-prometheus-evidence-collection.ps1 `
  -SubscriptionId "<subscription-id>" `
  -AksResourceGroup "<aks-rg>" `
  -AksClusterName "<aks-name>" `
  -MonitorResourceGroup "<monitor-rg>" `
  -MonitorWorkspaceName "<azure-monitor-workspace-name>" `
  -ExpectedMetricName "<optional-metric-name>"
```

### Authentication

1. Confirm Azure sign-in when prompted, then complete standard `az login` authentication using an account with access to the requested subscription. The script does not force device-code authentication.
2. The script selects that subscription as the active Azure CLI subscription.
3. Confirm the cluster connection. This retrieves AKS user credentials and updates the local kubeconfig (including overwriting an existing entry). Every Kubernetes query explicitly selects the requested cluster context.
4. Complete any sign-in requested by the cluster credential plugin. Before collecting resource evidence, the script verifies access with `kubectl get nodes` and a 60-second request timeout.

Declining either confirmation stops the script. Failed Azure authentication, subscription selection, credential retrieval, or cluster access also stops it. Missing `kubectl` is a blocking error, not a skipped check; install it and, for Microsoft Entra clusters, `kubelogin` (for example, using `az aks install-cli`), ensure the tools are on PATH, and rerun.

The script must successfully query nodes and kube-system pods and configmaps before generating a summary or reporting completion. Each Kubernetes request has a 60-second timeout. Authentication, RBAC, or network failures must be resolved before rerunning. Run from an interactive terminal; do not enter passwords or tokens into script parameters.

### Authentication checks

Run `powershell -NoProfile -File .\tests\authentication.tests.ps1` to exercise sign-in confirmation, cancellation, command failures, and verified cluster access with local test doubles. These checks do not contact Azure or modify kubeconfig.

## Output

The script generates an `output\prom-missing-metrics-<timestamp>` folder with:
- JSON/TXT dumps of relevant configuration
- snapshot of `ama-metrics` pods
- basic DCR/DCE and association signals
- `report-summary.md` with initial interpretation

## Recommended flow (1 week)

1. Run the script on 3-5 representative cases.
2. Complete the checklist for each case.
3. Use the prompt to generate a consistent conclusion per case.
4. Consolidate failure-domain patterns to feed the capstone experiment.
