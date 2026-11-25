# MVP Starter — Missing Prometheus Metrics Diagnostic

## TESTE PUSH

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
- Azure CLI (`az`) authenticated
- `kubectl` installed (optional, but recommended)
- Read permissions on AKS and Monitoring resources

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
