param(
    [Parameter(Mandatory = $true)][string]$SubscriptionId,
    [Parameter(Mandatory = $true)][string]$AksResourceGroup,
    [Parameter(Mandatory = $true)][string]$AksClusterName,
    [Parameter(Mandatory = $true)][string]$MonitorResourceGroup,
    [Parameter(Mandatory = $true)][string]$MonitorWorkspaceName,
    [string]$ExpectedMetricName = "",
    [string]$OutputRoot = ".\output",
    [switch]$ConfirmAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$collectionIssues = [System.Collections.Generic.List[string]]::new()

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Save-Text {
    param([string]$Path, [AllowEmptyString()][string]$Content)
    $Content | Out-File -LiteralPath $Path -Encoding utf8
}

function Save-Json {
    param([string]$Name, [object]$Value)
    Save-Text -Path (Join-Path $outDir $Name) -Content (ConvertTo-Json -InputObject $Value -Depth 100)
}

function Get-Value {
    param([AllowNull()][object]$Object, [string]$Path)
    $value = $Object
    foreach ($part in $Path.Split(".")) {
        if ($null -eq $value) { return }
        $property = $value.PSObject.Properties[$part]
        if ($null -eq $property) { return }
        $value = $property.Value
    }
    if ($null -ne $value) { return $value }
}

function Add-CollectionIssue {
    param([string]$Message)
    $collectionIssues.Add($Message)
    Write-Warning $Message
}

function Invoke-Tool {
    param([string]$Tool, [string[]]$Arguments)
    Write-Host "-> $Tool $($Arguments -join ' ')"
    $stderrPath = [System.IO.Path]::GetTempFileName()
    try {
        $isNative = (Get-Command $Tool -ErrorAction Stop).CommandType -eq "Application"
        $global:LASTEXITCODE = 0
        $ErrorActionPreference = "Continue"
        $text = & $Tool @Arguments 2> $stderrPath | Out-String
        $commandSucceeded = $?
        $exitCode = $global:LASTEXITCODE
        $ErrorActionPreference = "Stop"
        $stderr = Get-Content -LiteralPath $stderrPath -Raw
        # Windows PowerShell marks native stderr as a failed pipeline even on exit 0.
        if ($exitCode -ne 0 -or (-not $commandSucceeded -and -not $isNative)) {
            return [pscustomobject]@{ Success = $false; Text = $text; Error = "Exit code: $exitCode. $stderr $text" }
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Warning $stderr.Trim() }
        return [pscustomobject]@{ Success = $true; Text = $text; Error = "" }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Text = ""; Error = $_.Exception.Message }
    }
    finally {
        Remove-Item -LiteralPath $stderrPath -Force
    }
}

function Read-ToolJson {
    param([string]$Tool, [string[]]$Arguments)
    $result = Invoke-Tool -Tool $Tool -Arguments $Arguments
    if (-not $result.Success) {
        Add-CollectionIssue "$Tool $($Arguments -join ' '): $($result.Error)"
        return
    }
    try {
        if ([string]::IsNullOrWhiteSpace($result.Text)) { throw "Expected JSON, received empty output." }
        $value = ConvertFrom-Json -InputObject $result.Text
        if ($null -eq $value) { throw "Expected JSON, received null." }
        return $value
    }
    catch {
        Add-CollectionIssue "$Tool $($Arguments -join ' '): invalid JSON: $($_.Exception.Message)"
    }
}

function Get-ArmResource {
    param([string]$Id, [string]$ApiVersion)
    $resource = Read-ToolJson -Tool az -Arguments @("rest", "--method", "get", "--url", "${Id}?api-version=$ApiVersion", "--output", "json", "--only-show-errors")
    if ($null -eq $resource) { return }
    if ((Get-Value $resource "id") -ine $Id) {
        Add-CollectionIssue "ARM resource response ID does not match the requested resource: $Id"
        return
    }
    return $resource
}

function Get-ArmList {
    param([string]$Url)
    $items = @()
    do {
        $page = Read-ToolJson -Tool az -Arguments @("rest", "--method", "get", "--url", $Url, "--output", "json", "--only-show-errors")
        if ($null -eq $page) { return [pscustomobject]@{ Succeeded = $false; Items = $items } }
        if ($null -eq $page.PSObject.Properties["value"]) {
            Add-CollectionIssue "ARM list response has no value array: $Url"
            return [pscustomobject]@{ Succeeded = $false; Items = $items }
        }
        $items += @(Get-Value $page "value")
        $Url = [string](Get-Value $page "nextLink")
    } while ($Url)
    return [pscustomobject]@{ Succeeded = $true; Items = $items }
}

function Save-KubernetesText {
    param([string[]]$Arguments, [string]$Name)
    $result = Invoke-Tool -Tool kubectl -Arguments ($kubeArgs + $Arguments)
    if ($result.Success) {
        $text = $result.Text
        if ([string]::IsNullOrWhiteSpace($text)) { $text = "Command succeeded; no content returned." }
        Save-Text -Path (Join-Path $outDir $Name) -Content $text
    }
    else {
        Add-CollectionIssue "kubectl $($Arguments -join ' '): $($result.Error)"
        Save-Text -Path (Join-Path $outDir $Name) -Content "UNKNOWN - collection failed: $($result.Error)"
    }
    return $result
}

function Get-MetricPoints {
    param([AllowNull()][object]$Response, [string]$MetricName, [string]$Aggregation)
    foreach ($metric in @(Get-Value $Response "value")) {
        if ((Get-Value $metric "name.value") -ne $MetricName) { continue }
        foreach ($series in @(Get-Value $metric "timeseries")) {
            $dimension = (@(Get-Value $series "metadatavalues") | ForEach-Object {
                "$(Get-Value $_ 'name.value')=$(Get-Value $_ 'value')"
            } | Sort-Object) -join ";"
            if (-not $dimension) { $dimension = "workspace" }
            foreach ($point in @(Get-Value $series "data")) {
                $number = Get-Value $point $Aggregation
                if ($null -ne $number -and $number -is [ValueType]) {
                    [pscustomobject]@{ Dimension = $dimension; Timestamp = $point.timeStamp; Value = [double]$number }
                }
            }
        }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI (az) not found. Install it before running." }
$hasKubectl = $null -ne (Get-Command kubectl -ErrorAction SilentlyContinue)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "prom-missing-metrics-$timestamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$aksId = "/subscriptions/$SubscriptionId/resourceGroups/$AksResourceGroup/providers/Microsoft.ContainerService/managedClusters/$AksClusterName"
$workspaceId = "/subscriptions/$SubscriptionId/resourceGroups/$MonitorResourceGroup/providers/Microsoft.Monitor/accounts/$MonitorWorkspaceName"
$kubeArgs = @("--context", $AksClusterName, "--request-timeout=60s")

Write-Section "Authenticating Azure session"
if (-not $ConfirmAuthentication -and (Read-Host "Sign in to Azure for subscription $SubscriptionId using az login? [y/N]") -notmatch '^(y|yes)$') {
    throw "Azure authentication cancelled by user."
}
az login --output none
if ($LASTEXITCODE -ne 0) { throw "Azure authentication failed (exit code $LASTEXITCODE)." }
$selection = Invoke-Tool -Tool az -Arguments @("account", "set", "--subscription", $SubscriptionId)
if (-not $selection.Success) { throw "Failed to select subscription: $($selection.Error)" }

Write-Section "Connecting to AKS cluster"
if (-not $ConfirmAuthentication -and (Read-Host "Connect to AKS $AksResourceGroup/$AksClusterName and update the local kubeconfig? [y/N]") -notmatch '^(y|yes)$') {
    throw "AKS authentication cancelled by user."
}
if (-not $hasKubectl) {
    throw "kubectl not found. Install kubectl (and kubelogin for Microsoft Entra clusters), add the tools to PATH, and rerun. Azure CLI users can install them with: az aks install-cli"
}
$credentials = Invoke-Tool -Tool az -Arguments @("aks", "get-credentials", "-g", $AksResourceGroup, "-n", $AksClusterName, "--context", $AksClusterName, "--overwrite-existing")
if (-not $credentials.Success) { throw "Unable to retrieve AKS credentials: $($credentials.Error)" }
Write-Host "Verifying cluster access. Complete any sign-in requested by the cluster credential plugin (kubelogin)."
kubectl @kubeArgs get nodes
if ($LASTEXITCODE -ne 0) { throw "Cluster authentication/access failed. Check credentials, kubelogin, network access, and Kubernetes RBAC." }

Write-Section "Resolving linked DCRs and DCEs by resource ID"
$associations = Get-ArmList "${aksId}/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11"
Save-Json "06-dcr-associations-aks.json" ([ordered]@{
    status = $(if ($associations.Succeeded) { "Collected" } else { "Unknown" })
    message = "Associations on the requested AKS resource; DCRs and DCEs can be in other resource groups or subscriptions."
    associations = @($associations.Items)
})
$workspace = Get-ArmResource $workspaceId "2023-04-03"
$networkAccess = [string](Get-Value $workspace "properties.publicNetworkAccess")
if (-not $networkAccess) {
    $networkAccess = "Unknown"
    if ($null -ne $workspace) { Add-CollectionIssue "Workspace publicNetworkAccess was not returned; public access cannot be determined." }
}
Save-Text (Join-Path $outDir "workspace-network.txt") "Workspace: $workspaceId`r`nPublic network access: $networkAccess`r`nThis setting alone does not establish ingestion connectivity."

$dcrIds = @{}
$dceIds = @{}
$clusterDceIds = @{}
foreach ($association in $associations.Items) {
    $id = [string](Get-Value $association "properties.dataCollectionRuleId")
    if ($id) { $dcrIds[$id] = $true }
    $id = [string](Get-Value $association "properties.dataCollectionEndpointId")
    if ($id) { $dceIds[$id] = $true; $clusterDceIds[$id] = $true }
}
$clusterDcrIds = @($dcrIds.Keys)
$defaultDcr = [string](Get-Value $workspace "properties.defaultIngestionSettings.dataCollectionRuleResourceId")
$defaultDce = [string](Get-Value $workspace "properties.defaultIngestionSettings.dataCollectionEndpointResourceId")
if ($defaultDcr) { $dcrIds[$defaultDcr] = $true }
if ($defaultDce) { $dceIds[$defaultDce] = $true }
$dcrs = @()
$destinationWorkspaces = @{}
$linkDiscoveryComplete = $associations.Succeeded
foreach ($id in @($dcrIds.Keys | Sort-Object)) {
    $dcr = Get-ArmResource $id "2023-03-11"
    if ($null -eq $dcr) {
        if ($id -in $clusterDcrIds) { $linkDiscoveryComplete = $false }
        continue
    }
    $dcrs += $dcr
    $dceId = [string](Get-Value $dcr "properties.dataCollectionEndpointId")
    if ($dceId) {
        $dceIds[$dceId] = $true
        if ($id -in $clusterDcrIds) { $clusterDceIds[$dceId] = $true }
    }
    if ($id -in $clusterDcrIds) {
        foreach ($destination in @(Get-Value $dcr "properties.destinations.monitoringAccounts")) {
            $destinationId = [string](Get-Value $destination "accountResourceId")
            if ($destinationId) { $destinationWorkspaces[$destinationId] = $true }
        }
    }
}
foreach ($id in @($destinationWorkspaces.Keys)) {
    $destinationWorkspace = $workspace
    if ($id -ine $workspaceId) { $destinationWorkspace = Get-ArmResource $id "2023-04-03" }
    if ($null -eq $destinationWorkspace) { $linkDiscoveryComplete = $false; continue }
    $id = [string](Get-Value $destinationWorkspace "properties.defaultIngestionSettings.dataCollectionEndpointResourceId")
    if ($id) { $dceIds[$id] = $true; $clusterDceIds[$id] = $true }
}
Save-Json "04-dcr-list.json" ([ordered]@{
    status = $(if (-not $associations.Succeeded -or $null -eq $workspace -or $dcrs.Count -ne $dcrIds.Count) { "UnknownOrPartial" } elseif ($dcrs.Count) { "Collected" } else { "NotConfigured" })
    message = "Full DCR JSON resolved from AKS associations and workspace defaultIngestionSettings, not a resource-group list."
    clusterAssociatedRuleIds = $clusterDcrIds
    workspaceDefaultRuleId = $defaultDcr
    resources = @($dcrs)
})

$dces = @()
$amplsLinks = @()
foreach ($id in @($dceIds.Keys | Sort-Object)) {
    $dce = Get-ArmResource $id "2024-03-11"
    if ($null -eq $dce) {
        if ($clusterDceIds.ContainsKey($id)) { $linkDiscoveryComplete = $false }
        continue
    }
    $dces += $dce
    if (-not $clusterDceIds.ContainsKey($id)) { continue }
    foreach ($link in @(Get-Value $dce "properties.privateLinkScopedResources")) {
        $scopedResourceId = [string](Get-Value $link "resourceId")
        if ($scopedResourceId -match '^(.+/providers/Microsoft.Insights/privateLinkScopes/[^/]+)/scopedResources/[^/]+$') {
            $amplsLinks += [pscustomobject]@{ endpointResourceId = $id; amplsResourceId = $Matches[1]; scopedResourceId = $scopedResourceId }
        }
        else {
            $linkDiscoveryComplete = $false
            Add-CollectionIssue "DCE $id reports a private-link scope but no valid AMPLS scoped resource ID: $scopedResourceId"
        }
    }
}
Save-Json "05-dce-list.json" ([ordered]@{
    status = $(if (-not $linkDiscoveryComplete -or $null -eq $workspace -or $dces.Count -ne $dceIds.Count) { "UnknownOrPartial" } elseif ($dces.Count) { "Collected" } else { "NotConfigured" })
    message = "Full DCE JSON from direct AKS associations, linked DCRs and workspace default ingestion endpoints."
    clusterLinkedEndpointIds = @($clusterDceIds.Keys | Sort-Object)
    resources = @($dces)
})
$amplsStatus = if ($amplsLinks.Count) { "Associated" } elseif ($linkDiscoveryComplete) { "NotAssociated" } else { "Unknown" }
$amplsIds = @($amplsLinks | ForEach-Object { $_.amplsResourceId } | Sort-Object -Unique)
Save-Json "ampls-association.json" ([ordered]@{
    status = $amplsStatus
    verificationComplete = $linkDiscoveryComplete
    clusterResourceId = $aksId
    amplsResourceIds = $amplsIds
    links = @($amplsLinks)
    explanation = "Checks privateLinkScopedResources on DCEs linked through AKS associations, DCRs and their destination workspaces. Workspace defaults alone do not prove a cluster association. This is not a DNS/VNet connectivity test."
})

Write-Section "Collecting workspace ingestion limits and utilization (last 60 minutes UTC)"
$metricsEnd = (Get-Date).ToUniversalTime()
$metricsStart = $metricsEnd.AddHours(-1)
$metricArgs = @("monitor", "metrics", "list", "--resource", $workspaceId, "--namespace", "Microsoft.Monitor/accounts",
    "--start-time", $metricsStart.ToString("yyyy-MM-ddTHH:mm:ssZ"), "--end-time", $metricsEnd.ToString("yyyy-MM-ddTHH:mm:ssZ"),
    "--interval", "PT1M", "--output", "json", "--only-show-errors")
$counts = Read-ToolJson az ($metricArgs + @("--metrics", "ActiveTimeSeries", "ActiveTimeSeriesLimit", "EventsPerMinuteIngested", "EventsPerMinuteIngestedLimit", "--aggregation", "Maximum"))
$percentages = Read-ToolJson az ($metricArgs + @("--metrics", "ActiveTimeSeriesPercentUtilization", "EventsPerMinuteIngestedPercentUtilization", "--aggregation", "Average"))
if ($null -ne $counts) { Save-Json "ingestion-counts-and-limits.json" $counts }
if ($null -ne $percentages) { Save-Json "ingestion-utilization.json" $percentages }
$ingestionRows = @()
foreach ($definition in @(
    @{ Label = "Events per minute"; Base = "EventsPerMinuteIngested" },
    @{ Label = "Active time series"; Base = "ActiveTimeSeries" }
)) {
    $usagePoints = @(Get-MetricPoints $counts $definition.Base "maximum")
    $limitPoints = @(Get-MetricPoints $counts ($definition.Base + "Limit") "maximum")
    $percentPoints = @(Get-MetricPoints $percentages ($definition.Base + "PercentUtilization") "average")
    $dimensions = @(@($usagePoints + $limitPoints + $percentPoints) | ForEach-Object { $_.Dimension } | Sort-Object -Unique)
    if ($dimensions.Count -eq 0) { $dimensions = @("workspace") }
    foreach ($dimension in $dimensions) {
        $usage = $usagePoints | Where-Object { $_.Dimension -eq $dimension } | Sort-Object Timestamp -Descending | Select-Object -First 1
        $limit = $limitPoints | Where-Object { $_.Dimension -eq $dimension } | Sort-Object Timestamp -Descending | Select-Object -First 1
        $utilization = @($percentPoints | Where-Object { $_.Dimension -eq $dimension } | Sort-Object Timestamp -Descending)
        $latest = $utilization | Select-Object -First 1
        $peak = if ($utilization.Count) { ($utilization | Measure-Object Value -Maximum).Maximum } else { $null }
        $status = if ($null -eq $limit -or $null -eq $usage -or $null -eq $latest) { "Unknown" } else { "Measured" }
        if ($status -eq "Unknown") { Add-CollectionIssue "$($definition.Label) ($dimension): missing usage, limit or utilization samples. Cannot confirm ingestion status." }
        $ingestionRows += [pscustomobject]@{
            metric = $definition.Label; dimension = $dimension; status = $status
            latestUsage = $(if ($usage) { $usage.Value } else { $null })
            usageTimestampUtc = $(if ($usage) { $usage.Timestamp } else { $null })
            latestLimit = $(if ($limit) { $limit.Value } else { $null })
            limitTimestampUtc = $(if ($limit) { $limit.Timestamp } else { $null })
            latestUtilizationPercent = $(if ($latest) { $latest.Value } else { $null })
            utilizationTimestampUtc = $(if ($latest) { $latest.Timestamp } else { $null })
            peakUtilizationPercent = $peak; utilizationSamples = $utilization.Count
            exceededInObservedSamples = $(if ($null -eq $peak) { "Unknown" } elseif ($peak -gt 100) { "Yes" } else { "No" })
            reachedLimitInObservedSamples = $(if ($null -eq $peak) { "Unknown" } elseif ($peak -ge 100) { "Yes" } else { "No" })
        }
    }
}
Save-Json "ingestion-status.json" ([ordered]@{
    workspaceResourceId = $workspaceId
    startUtc = $metricsStart.ToString("o"); endUtc = $metricsEnd.ToString("o"); interval = "PT1M"
    interpretation = "Workspace-wide metrics without dimension filters; Azure rejects explicit filtering on the hidden StampColor dimension. Any returned series metadata is preserved. Limits/usage use Maximum; official utilization uses Average in each one-minute bucket. Peak is the highest observed one-minute utilization, not proof about unsampled periods or dropped data. Limits may change; each latest value has its own timestamp. No hardcoded quota defaults."
    metrics = $ingestionRows
})
$ingestionText = $ingestionRows | Format-List * | Out-String -Width 240
Save-Text (Join-Path $outDir "ingestion-status.txt") "UTC window: $($metricsStart.ToString('o')) to $($metricsEnd.ToString('o'))`r`n$ingestionText"

Write-Section "Collecting ama-metrics pod status and prometheus-collector logs"
$pods = Read-ToolJson kubectl ($kubeArgs + @("get", "pods", "-n", "kube-system", "-o", "json"))
if ($null -eq $pods -or $null -eq $pods.PSObject.Properties["items"]) { throw "Unable to query kube-system pods. Collection is incomplete; see console errors." }
$amaPods = @(Get-Value $pods "items" | Where-Object { $_.metadata.name -like "ama-metrics*" })
$statusRows = @()
$collectorPods = @()
$errorLines = [System.Collections.Generic.List[string]]::new()
foreach ($pod in $amaPods) {
    $podName = $pod.metadata.name
    $statuses = @(Get-Value $pod "status.containerStatuses")
    $isReady = @(Get-Value $pod "status.conditions" | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -gt 0
    foreach ($container in @(Get-Value $pod "spec.containers")) {
        $containerStatus = $statuses | Where-Object { $_.name -eq $container.name } | Select-Object -First 1
        $statusRows += [pscustomobject]@{
            Pod = $podName; Phase = (Get-Value $pod "status.phase"); PodReady = $isReady
            Container = $container.name; Ready = (Get-Value $containerStatus "ready")
            Restarts = (Get-Value $containerStatus "restartCount")
            State = (ConvertTo-Json -InputObject (Get-Value $containerStatus "state") -Compress -Depth 10)
            PreviousState = (ConvertTo-Json -InputObject (Get-Value $containerStatus "lastState") -Compress -Depth 10)
        }
        if ($container.name -ne "prometheus-collector") { continue }
        $collectorPods += $pod
        $logArgs = @("logs", $podName, "-n", "kube-system", "-c", "prometheus-collector", "--since=1h", "--tail=5000", "--timestamps=true", "--pod-running-timeout=30s")
        $log = Save-KubernetesText $logArgs "$podName-prometheus-collector.log"
        if ($log.Success) {
            foreach ($line in ($log.Text -split '\r?\n' | Where-Object { $_ -match '(?i)\b(error|warn(ing)?|fatal|exception|throttl\w*)\b' })) {
                $errorLines.Add("${podName}: $line")
            }
        }
        if ((Get-Value $containerStatus "restartCount") -gt 0) {
            $previousLog = Save-KubernetesText ($logArgs + @("--previous")) "$podName-prometheus-collector-previous.log"
            if ($previousLog.Success) {
                foreach ($line in ($previousLog.Text -split '\r?\n' | Where-Object { $_ -match '(?i)\b(error|warn(ing)?|fatal|exception|throttl\w*)\b' })) {
                    $errorLines.Add("${podName} (previous): $line")
                }
            }
        }
    }
}
$podStatusText = if ($statusRows.Count) { $statusRows | Format-Table -AutoSize -Wrap | Out-String -Width 260 } else { "No ama-metrics pods found in kube-system." }
Save-Text (Join-Path $outDir "ama-metrics-status.txt") $podStatusText
Save-Json "ama-metrics-status.json" ([ordered]@{ podCount = $amaPods.Count; containers = $statusRows })
if ($errorLines.Count -eq 0) { $errorLines.Add("No matching error/warning lines in successfully retrieved logs. This is not proof of health; check collection issues and the bounded log window.") }
Save-Text (Join-Path $outDir "ama-metrics-errors-warnings.txt") ($errorLines -join "`r`n")

Write-Section "Reading collection configuration and diagnostic files from one running Linux collector"
$snapshotPod = $collectorPods | Where-Object {
    (Get-Value $_ "status.phase") -eq "Running" -and $_.metadata.name -notlike "ama-metrics-win*" -and
    (Get-Value $_ "spec.os.name") -ne "windows" -and
    @(Get-Value $_ "status.containerStatuses" | Where-Object {
        $_.name -eq "prometheus-collector" -and $null -ne (Get-Value $_ "state.running")
    }).Count -gt 0
} | Sort-Object { $_.metadata.name } | Select-Object -First 1
if ($null -ne $snapshotPod) {
    $snapshotScript = @'
set -eu
printf 'Read-only collector snapshot. Config files are capped at 1 MiB; diagnostic logs at 5000 lines.\n'
printf 'Secret mounts, service-account tokens, environment variables, certs and private keys are excluded.\n'
for root in /etc/config/settings /opt/microsoft/otelcollector /etc/prometheus; do
  if [ -d $root ]; then
    printf '\nCONFIG ROOT: %s\n' $root
    find -L $root -maxdepth 4 \( -name certs -o -name secrets -o -name token \) -prune -o -type f \( -name '*.yml' -o -name '*.yaml' -o -name '*.json' -o -name '*.toml' -o -name '*.conf' -o -name prometheus-config -o -name config -o -name settings \) -exec printf '\nFILE: %s\n' {} \; -exec wc -c {} \; -exec head -c 1048576 {} \; -exec printf '\nEND FILE\n' \;
  else
    printf '\nNot present in this image: %s\n' $root
  fi
done
for file in /MetricsExtensionConsoleDebugLog.log /opt/microsoft/linuxmonagent/mdsd.qos /opt/microsoft/linuxmonagent/mdsd.info /opt/microsoft/linuxmonagent/mdsd.warn /opt/microsoft/linuxmonagent/mdsd.err; do
  if [ -f $file ]; then
    printf '\nDIAGNOSTIC LOG: %s\n' $file
    tail -n 5000 $file
  else
    printf '\nNot present in this image: %s\n' $file
  fi
done
'@
    $snapshot = Save-KubernetesText @("exec", $snapshotPod.metadata.name, "-n", "kube-system", "-c", "prometheus-collector", "--", "sh", "-c", $snapshotScript) "collector-files.txt"
    if ($snapshot.Success) {
        $matches = @($snapshot.Text -split '\r?\n' | Where-Object { $_ -match '(?i)\b(error|warn(ing)?|fatal|exception|throttl\w*)\b' })
        Save-Text (Join-Path $outDir "collector-file-errors-warnings.txt") $(if ($matches.Count) { $matches -join "`r`n" } else { "No matching error/warning lines in the collected file excerpts." })
    }
}
else {
    Save-Text (Join-Path $outDir "collector-files.txt") "Not collected: no running Linux pod containing prometheus-collector. Windows container filesystem collection is not supported."
    if ($amaPods.Count) { Add-CollectionIssue "No running Linux prometheus-collector container is available for file inspection." }
}

Write-Section "Collecting only documented scrape ConfigMaps"
$configStatus = @()
foreach ($name in @("ama-metrics-settings-configmap", "ama-metrics-prometheus-config", "ama-metrics-prometheus-config-node", "ama-metrics-prometheus-config-node-windows")) {
    $result = Invoke-Tool kubectl ($kubeArgs + @("get", "configmap", $name, "-n", "kube-system", "--ignore-not-found", "-o", "yaml"))
    if (-not $result.Success) {
        Add-CollectionIssue "ConfigMap ${name}: $($result.Error)"
        $configStatus += "${name}: Unknown - $($result.Error)"
    }
    elseif ([string]::IsNullOrWhiteSpace($result.Text)) {
        $configStatus += "${name}: Not present (optional customization; defaults apply)."
    }
    else {
        $configStatus += "${name}: Present - $name.yaml"
        Save-Text (Join-Path $outDir "$name.yaml") $result.Text
    }
}
Save-Text (Join-Path $outDir "configmaps-status.txt") ($configStatus -join "`r`n")

Write-Section "Collecting Azure PodMonitor and ServiceMonitor CRDs and resources"
$monitorStatus = @()
foreach ($resource in @("podmonitors.azmonitoring.coreos.com", "servicemonitors.azmonitoring.coreos.com")) {
    $crd = Invoke-Tool kubectl ($kubeArgs + @("get", "crd", $resource, "--ignore-not-found", "-o", "yaml"))
    if (-not $crd.Success) {
        Add-CollectionIssue "CRD ${resource}: $($crd.Error)"
        $monitorStatus += "${resource}: Unknown - CRD query failed."
        continue
    }
    if ([string]::IsNullOrWhiteSpace($crd.Text)) {
        $monitorStatus += "${resource}: CRD not installed; no Azure-managed instances can exist."
        continue
    }
    Save-Text (Join-Path $outDir "$resource-crd.yaml") $crd.Text
    $monitorList = Read-ToolJson kubectl ($kubeArgs + @("get", $resource, "--all-namespaces", "-o", "json"))
    if ($null -eq $monitorList -or $null -eq $monitorList.PSObject.Properties["items"]) {
        if ($null -ne $monitorList) { Add-CollectionIssue "${resource}: invalid list response; items array missing." }
        $monitorStatus += "${resource}: CRD installed; instances Unknown - list query failed."
        continue
    }
    $monitorCount = @(Get-Value $monitorList "items").Count
    if ($monitorCount -eq 0) {
        $monitorStatus += "${resource}: CRD installed; no custom-resource instances found in any namespace."
        continue
    }
    $instances = Save-KubernetesText @("get", $resource, "--all-namespaces", "-o", "yaml") "$resource.yaml"
    $monitorStatus += "${resource}: CRD installed; $monitorCount instances listed. Content in $resource.yaml. YAML query succeeded: $($instances.Success)."
}
Save-Text (Join-Path $outDir "monitors-status.txt") ($monitorStatus -join "`r`n")

$readyCount = @($amaPods | Where-Object {
    @(Get-Value $_ "status.conditions" | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }).Count -gt 0
}).Count
$completion = if ($collectionIssues.Count) { "Incomplete" } else { "Complete" }
$hints = @()
if ($clusterDcrIds.Count -eq 0 -and $associations.Succeeded) { $hints += "No AKS DCR association found; workspace defaults alone do not onboard a cluster." }
if ($amaPods.Count -eq 0) { $hints += "No ama-metrics pods found in kube-system." }
if ($readyCount -lt $amaPods.Count) { $hints += "Some ama-metrics pods are not Ready; inspect container state and logs." }
if ($collectionIssues.Count) { $hints += "Some checks are Unknown or failed. Review collection-issues.txt; do not treat missing evidence as healthy." }
if ($hints.Count -eq 0) { $hints += "Review linked resources, scrape configuration, collector errors and ingestion utilization before selecting a failure domain." }
Save-Text (Join-Path $outDir "collection-issues.txt") $(if ($collectionIssues.Count) { $collectionIssues -join "`r`n" } else { "No collection command or data-availability issues detected." })
$summary = @"
# Report Summary - Missing Prometheus Metrics

## Context
- Subscription: $SubscriptionId
- AKS: $AksResourceGroup / $AksClusterName
- Monitor Workspace: $MonitorResourceGroup / $MonitorWorkspaceName
- Expected metric: $(if ($ExpectedMetricName) { $ExpectedMetricName } else { "not provided" })

## Initial signals
- Collection status: $completion
- Cluster-associated DCRs: $(if ($associations.Succeeded) { $clusterDcrIds.Count } else { "Unknown" })
- DCR JSON resources resolved: $($dcrs.Count)
- DCE JSON resources resolved: $($dces.Count)
- Cluster AMPLS association: $amplsStatus
- AMPLS resource IDs: $(if ($amplsIds.Count) { $amplsIds -join ", " } elseif ($amplsStatus -eq "Unknown") { "Unknown - evidence incomplete" } else { "None" })
- Workspace public network access: $networkAccess
- ama-metrics pods found: $($amaPods.Count)
- ama-metrics pods ready: $readyCount
- Collection issues: $($collectionIssues.Count)

## Ingestion status (workspace-wide, last 60 minutes UTC)
$(($ingestionRows | ForEach-Object { "- $($_.metric) [$($_.dimension)]: limit=$($_.latestLimit); usage=$($_.latestUsage); utilization=$($_.latestUtilizationPercent)%; peak=$($_.peakUtilizationPercent)%; exceeded=$($_.exceededInObservedSamples); reached=$($_.reachedLimitInObservedSamples); status=$($_.status)" }) -join "`r`n")

See ingestion-status.txt and ingestion-status.json for timestamps, sample counts and aggregation. Unknown is not zero. No means no exceedance observed in available one-minute samples, not proof about missing periods.

## Findings and next steps
$(($hints | ForEach-Object { "- $_" }) -join "`r`n")

## Evidence
- 04-dcr-list.json / 05-dce-list.json: full linked resource content, with explicit discovery status.
- ampls-association.json: cluster-linked DCE evidence and full AMPLS resource IDs.
- workspace-network.txt: public access setting without a workspace JSON dump.
- ama-metrics-status.txt and prometheus-collector log files: container readiness, restarts, errors and warnings.
- collector-files.txt: read-only configuration/diagnostic excerpts from one running Linux collector.
- configmaps-status.txt and monitors-status.txt: present, absent, or unknown plus readable YAML where available.
- collection-issues.txt: command failures and missing evidence.
"@
Save-Text (Join-Path $outDir "report-summary.md") $summary
Write-Host "`nCollection $completion. Artifacts in: $outDir"
if ($collectionIssues.Count) { throw "Collection is incomplete ($($collectionIssues.Count) issues). See report-summary.md and collection-issues.txt." }
