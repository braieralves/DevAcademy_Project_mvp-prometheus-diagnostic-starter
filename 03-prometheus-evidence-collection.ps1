param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$AksResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$AksClusterName,

    [Parameter(Mandatory = $true)]
    [string]$MonitorResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$MonitorWorkspaceName,

    [string]$ExpectedMetricName = "",
    [string]$OutputRoot = ".\output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Save-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $Content | Out-File -FilePath $Path -Encoding utf8
}

function Run-External {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    Write-Host "-> $Command"
    try {
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = "Continue"
        $out = Invoke-Expression $Command 2>&1 | Out-String
        $commandSucceeded = $?
        $exitCode = $global:LASTEXITCODE
        $ErrorActionPreference = "Stop"
        if (-not $commandSucceeded -or $exitCode -ne 0) {
            throw "Exit code: $exitCode`r`n$out"
        }
        Save-Text -Path $OutputPath -Content $out
        return $true
    }
    catch {
        $msg = "COMMAND FAILED: $Command`r`nERROR: $($_.Exception.Message)"
        Save-Text -Path $OutputPath -Content $msg
        Write-Warning $msg
        return $false
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found. Install it before running."
}

$hasKubectl = $null -ne (Get-Command kubectl -ErrorAction SilentlyContinue)

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "prom-missing-metrics-$timestamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Section "Context"
Write-Host "Output: $outDir"
Write-Host "Subscription: $SubscriptionId"
Write-Host "AKS: $AksResourceGroup / $AksClusterName"
Write-Host "Monitor Workspace: $MonitorResourceGroup / $MonitorWorkspaceName"
if ($ExpectedMetricName -ne "") {
    Write-Host "Expected metric: $ExpectedMetricName"
}

Write-Section "Authenticating Azure session"
if ((Read-Host "Sign in to Azure for subscription $SubscriptionId using az login? [y/N]") -notmatch '^(y|yes)$') {
    throw "Azure authentication cancelled by user."
}
az login --output none
if ($LASTEXITCODE -ne 0) {
    throw "Azure authentication failed (exit code $LASTEXITCODE)."
}

Write-Section "Selecting subscription"
$subscriptionSelected = Run-External -Command "az account set --subscription `"$SubscriptionId`"" -OutputPath (Join-Path $outDir "01-account-set.txt")
if (-not $subscriptionSelected) {
    throw "Failed to select subscription $SubscriptionId. Check 01-account-set.txt for details."
}
$azureAuthenticated = Run-External -Command "az account show -o json" -OutputPath (Join-Path $outDir "00-account-show.json")
if (-not $azureAuthenticated) {
    throw "Unable to verify the selected Azure session. Check 00-account-show.json for details."
}

Write-Section "Connecting to AKS cluster"
if ((Read-Host "Connect to AKS $AksResourceGroup/$AksClusterName and update the local kubeconfig? [y/N]") -notmatch '^(y|yes)$') {
    throw "AKS authentication cancelled by user."
}
if (-not $hasKubectl) {
    throw "kubectl not found. Install kubectl (and kubelogin for Microsoft Entra clusters), add the tools to PATH, and rerun. Azure CLI users can install them with: az aks install-cli"
}
$credentialsLoaded = Run-External -Command "az aks get-credentials -g `"$AksResourceGroup`" -n `"$AksClusterName`" --context `"$AksClusterName`" --overwrite-existing" -OutputPath (Join-Path $outDir "10-aks-get-credentials.txt")
if (-not $credentialsLoaded) {
    throw "Unable to retrieve AKS credentials. Check 10-aks-get-credentials.txt and your AKS access permissions."
}
Write-Host "Verifying cluster access. Complete any sign-in requested by the cluster credential plugin."
Write-Host "Microsoft Entra clusters may require kubelogin on PATH."
kubectl --context "$AksClusterName" get nodes --request-timeout=60s
$aksConnected = $LASTEXITCODE -eq 0
Save-Text -Path (Join-Path $outDir "10-aks-authentication.txt") -Content "Cluster access verified: $aksConnected"
if (-not $aksConnected) {
    throw "Cluster authentication/access failed. Check credentials, kubelogin, network access, and Kubernetes RBAC. Collection cannot continue without kubectl access."
}

Write-Section "Collecting AKS"
$aksCollected = Run-External -Command "az aks show -g `"$AksResourceGroup`" -n `"$AksClusterName`" -o json" -OutputPath (Join-Path $outDir "02-aks-show.json")
if (-not $aksCollected) {
    throw "Unable to read AKS configuration. Check 02-aks-show.json for details."
}
$aksJson = Get-Content (Join-Path $outDir "02-aks-show.json") -Raw
$aks = $aksJson | ConvertFrom-Json
$aksId = [string]$aks.id

Write-Section "Collecting Azure Monitor workspace"
Run-External -Command "az resource show --resource-group `"$MonitorResourceGroup`" --name `"$MonitorWorkspaceName`" --resource-type Microsoft.Monitor/accounts -o json" -OutputPath (Join-Path $outDir "03-monitor-workspace.json") | Out-Null

Write-Section "Collecting DCR / DCE in resource group"
Run-External -Command "az monitor data-collection rule list --resource-group `"$MonitorResourceGroup`" -o json" -OutputPath (Join-Path $outDir "04-dcr-list.json") | Out-Null
Run-External -Command "az monitor data-collection endpoint list --resource-group `"$MonitorResourceGroup`" -o json" -OutputPath (Join-Path $outDir "05-dce-list.json") | Out-Null

Write-Section "Collecting AKS DCR association"
Run-External -Command "az monitor data-collection rule association list --resource `"$aksId`" -o json" -OutputPath (Join-Path $outDir "06-dcr-associations-aks.json") | Out-Null

Write-Section "Collecting AMPLS (subscription)"
Run-External -Command "az monitor private-link-scope list --subscription `"$SubscriptionId`" -o json" -OutputPath (Join-Path $outDir "07-ampls-list.json") | Out-Null

Write-Section "Collecting data via kubectl"
$nodesCollected = Run-External -Command "kubectl --context `"$AksClusterName`" get nodes -o wide --request-timeout=60s" -OutputPath (Join-Path $outDir "11-k8s-nodes.txt")
if (-not $nodesCollected) {
    throw "Unable to query cluster nodes. Check 11-k8s-nodes.txt. Collection is incomplete."
}
$podsCollected = Run-External -Command "kubectl --context `"$AksClusterName`" get pods -n kube-system -o json --request-timeout=60s" -OutputPath (Join-Path $outDir "12-kube-system-pods.json")
if (-not $podsCollected) {
    throw "Unable to query kube-system pods. Check 12-kube-system-pods.json and Kubernetes RBAC. Collection is incomplete."
}
$configMapsCollected = Run-External -Command "kubectl --context `"$AksClusterName`" get configmap -n kube-system --request-timeout=60s" -OutputPath (Join-Path $outDir "13-kube-system-configmaps.txt")
if (-not $configMapsCollected) {
    throw "Unable to query kube-system configmaps. Check 13-kube-system-configmaps.txt and Kubernetes RBAC. Collection is incomplete."
}

Write-Section "Generating initial summary"
$dcrAssocJson = Get-Content (Join-Path $outDir "06-dcr-associations-aks.json") -Raw
$dcrAssoc = $dcrAssocJson | ConvertFrom-Json
$dcrAssocCount = @($dcrAssoc).Count

$amaCount = -1
$amaReady = -1
if ($hasKubectl -and (Test-Path (Join-Path $outDir "12-kube-system-pods.json"))) {
    $podsJson = Get-Content (Join-Path $outDir "12-kube-system-pods.json") -Raw
    $pods = $podsJson | ConvertFrom-Json
    $amaPods = @($pods.items | Where-Object { $_.metadata.name -like "*ama-metrics*" })
    $amaCount = $amaPods.Count
    if ($amaCount -gt 0) {
        $amaReady = @(
            $amaPods | Where-Object {
                $_.status.containerStatuses -and
                ($_.status.containerStatuses | Where-Object { $_.ready -eq $true }).Count -gt 0
            }
        ).Count
    }
}

$hints = @()
if ($dcrAssocCount -eq 0) {
    $hints += "- No DCR association on AKS: strong indication of a DCR/DCE domain failure."
}
if ($amaCount -eq 0 -and $hasKubectl) {
    $hints += "- No ama-metrics pod found in kube-system: check onboarding/agent."
}
if ($amaCount -gt 0 -and $amaReady -ge 0 -and $amaReady -lt $amaCount) {
    $hints += "- Some ama-metrics pods are not ready: investigate agent health."
}
if (-not $aksConnected) {
    $hints += "- AKS access was not verified: check kubectl availability, credentials, kubelogin, network access, and Kubernetes RBAC."
}
if ($hints.Count -eq 0) {
    $hints += "- No obvious blocker in this initial collection. Proceed with target/scrape/query validation."
}

$summary = @"
# Report Summary - Missing Prometheus Metrics

## Context
- Subscription: $SubscriptionId
- AKS: $AksResourceGroup / $AksClusterName
- Monitor Workspace: $MonitorResourceGroup / $MonitorWorkspaceName
- Expected metric: $(if ($ExpectedMetricName -eq "") { "not provided" } else { $ExpectedMetricName })

## Initial signals
- Azure session authenticated: $azureAuthenticated
- DCR associations on AKS: $dcrAssocCount
- kubectl available: $hasKubectl
- AKS access verified (kubectl get nodes): $aksConnected
- ama-metrics pods found: $amaCount
- ama-metrics pods ready: $amaReady

## Initial hypotheses
$(($hints -join "`r`n"))

## Next steps
1. Confirm target discovery and UP/DOWN status.
2. Validate scraping and related errors.
3. Review query/labels/time window for the expected metric.
4. Consolidate the primary failure domain based on evidence.
"@

Save-Text -Path (Join-Path $outDir "report-summary.md") -Content $summary

Write-Host ""
Write-Host "Collection complete. Artifacts in: $outDir" -ForegroundColor Green
