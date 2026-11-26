$ErrorActionPreference = "Stop"
$collector = Join-Path $PSScriptRoot "..\03-prometheus-evidence-collection.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("prom-evidence-tests-" + [guid]::NewGuid())
$state = @{
    Scenario = ""
    Calls = [System.Collections.Generic.List[string]]::new()
    Prompts = [System.Collections.Generic.List[string]]::new()
}
$clusterId = "/subscriptions/test-subscription/resourceGroups/test-aks-rg/providers/Microsoft.ContainerService/managedClusters/test-aks"
$workspaceId = "/subscriptions/test-subscription/resourceGroups/test-monitor-rg/providers/Microsoft.Monitor/accounts/test-workspace"
$dcrId = "/subscriptions/other-subscription/resourceGroups/managed-rg/providers/Microsoft.Insights/dataCollectionRules/linked-rule"
$fixtureDceId = "/subscriptions/other-subscription/resourceGroups/managed-rg/providers/Microsoft.Insights/dataCollectionEndpoints/linked-endpoint"
$defaultDcrId = "/subscriptions/test-subscription/resourceGroups/MA_workspace_managed/providers/Microsoft.Insights/dataCollectionRules/default-rule"
$defaultDceId = "/subscriptions/test-subscription/resourceGroups/MA_workspace_managed/providers/Microsoft.Insights/dataCollectionEndpoints/default-endpoint"
$amplsId = "/subscriptions/other-subscription/resourceGroups/network-rg/providers/Microsoft.Insights/privateLinkScopes/test-scope"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-IngestionBlock {
    param([string]$Text, [string]$Title)
    $pattern = "(?s)={40,}\r?\n" + [regex]::Escape($Title) + "\r?\n={40,}\r?\n(?<body>.*?)(?=\r?\n={40,}\r?\n|\z)"
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) { $match.Groups["body"].Value } else { "" }
}

function Read-Host {
    param([string]$Prompt)
    $state.Prompts.Add($Prompt)
    if ($state.Scenario -eq "decline-azure") { return "n" }
    if ($state.Scenario -eq "decline-cluster" -and $Prompt -like "Connect to AKS*") { return "n" }
    return "y"
}

function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq "kubectl" -and $state.Scenario -eq "missing-kubectl") { return }
    Microsoft.PowerShell.Core\Get-Command -Name $Name -ErrorAction SilentlyContinue
}

function Write-FixtureJson {
    param([object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 30 -Compress
}

function az {
    $command = $args -join " "
    $state.Calls.Add("az $command")
    $global:LASTEXITCODE = 0
    if ($command -like "login *") {
        if ($state.Scenario -eq "login-failure") { $global:LASTEXITCODE = 1 }
    }
    elseif ($command -like "account set *") {
        if ($state.Scenario -eq "subscription-failure") {
            $global:LASTEXITCODE = 1
            "Subscription access denied"
        }
    }
    elseif ($command -like "aks get-credentials *") {
        if ($state.Scenario -eq "credentials-failure") {
            $global:LASTEXITCODE = 1
            "Credential access denied"
        }
    }
    elseif ($command -like "rest *") {
        $url = [string]$args[([array]::IndexOf($args, "--url") + 1)]
        if ($url -like "*dataCollectionRuleAssociations*") {
            if ($state.Scenario -eq "association-denied") {
                $global:LASTEXITCODE = 1; "Forbidden"; return
            }
            if ($state.Scenario -eq "absent") { '{"value":[]}'; return }
            if ($state.Scenario -eq "workspace-only-ampls") {
                Write-FixtureJson @{ value = @(@{ properties = @{ dataCollectionEndpointId = $fixtureDceId } }) }
                return
            }
            Write-FixtureJson @{
                value = @(@{ properties = @{ dataCollectionRuleId = $dcrId } })
                nextLink = "https://management.azure.com/fixture-associations-page2"
            }
        }
        elseif ($url -eq "https://management.azure.com/fixture-associations-page2") {
            Write-FixtureJson @{ value = @(@{ properties = @{ dataCollectionEndpointId = $fixtureDceId } }) }
        }
        elseif ($url -like "${clusterId}?api-version=*") {
            Write-FixtureJson @{ id = $clusterId; location = "canadacentral"; properties = @{ kubernetesVersion = "1.35.8"; azureMonitorProfile = @{ metrics = @{ enabled = $true } } } }
        }
        elseif ($url -like "${workspaceId}?api-version=*") {
            $properties = @{ publicNetworkAccess = "Disabled" }
            if ($state.Scenario -ne "absent") {
                $properties.defaultIngestionSettings = @{ dataCollectionRuleResourceId = $defaultDcrId; dataCollectionEndpointResourceId = $defaultDceId }
            }
            Write-FixtureJson @{ id = $workspaceId; properties = $properties }
        }
        elseif ($url -like "${dcrId}?api-version=*") {
            if ($state.Scenario -eq "dcr-denied") {
                $global:LASTEXITCODE = 1; "Forbidden"; return
            }
            Write-FixtureJson @{ id = $dcrId; properties = @{
                dataCollectionEndpointId = $fixtureDceId
                destinations = @{ monitoringAccounts = @(@{ accountResourceId = $workspaceId; name = "destination" }) }
                dataFlows = @(@{ streams = @("Microsoft-PrometheusMetrics"); destinations = @("destination") })
            } }
        }
        elseif ($url -like "${defaultDcrId}?api-version=*") {
            Write-FixtureJson @{ id = $defaultDcrId; properties = @{ dataCollectionEndpointId = $defaultDceId } }
        }
        elseif ($url -like "${fixtureDceId}?api-version=*") {
            if ($state.Scenario -eq "dce-denied") {
                $global:LASTEXITCODE = 1; "Forbidden"; return
            }
            $links = @()
            if ($state.Scenario -notin @("not-associated", "default-only-ampls", "workspace-only-ampls")) {
                $links = @(@{ resourceId = "$amplsId/scopedResources/dce-link"; scopeId = "immutable-scope-id-not-an-arm-id" })
            }
            Write-FixtureJson @{ id = $fixtureDceId; properties = @{ privateLinkScopedResources = $links; metricsIngestion = @{ endpoint = "https://fixture.ingest.monitor.azure.com" } } }
        }
        elseif ($url -like "${defaultDceId}?api-version=*") {
            $links = @()
            if ($state.Scenario -in @("default-only-ampls", "workspace-only-ampls")) { $links = @(@{ resourceId = "$amplsId/scopedResources/default-link" }) }
            Write-FixtureJson @{ id = $defaultDceId; properties = @{ privateLinkScopedResources = $links } }
        }
        else { throw "Unexpected ARM URL: $url" }
    }
    elseif ($command -like "monitor metrics list *") {
        if ($args -contains "--filter") {
            $global:LASTEXITCODE = 1
            "BadRequest: StampColor is a hidden dimension and cannot be requested."
            return
        }
        if ($state.Scenario -eq "metrics-denied") { $global:LASTEXITCODE = 1; "Forbidden"; return }
        if ($state.Scenario -eq "no-metrics") { '{"value":[]}'; return }
        $metricStart = [array]::IndexOf($args, "--metrics") + 1
        $metricEnd = [array]::IndexOf($args, "--aggregation") - 1
        $metricNames = $args[$metricStart..$metricEnd]
        $metrics = @()
        foreach ($metricName in $metricNames) {
            $aggregation = if ($metricName -like "*PercentUtilization") { "average" } else { "maximum" }
            $value = if ($metricName -like "*Limit") { 2000000 } elseif ($metricName -like "*PercentUtilization") { 0 } else { 0 }
            if ($metricName -eq "EventsPerMinuteIngestedPercentUtilization") { $value = 101 }
            if ($metricName -eq "ActiveTimeSeriesPercentUtilization") { $value = 100 }
            if ($metricName -eq "EventsPerMinuteIngested") { $value = 2020000 }
            if ($metricName -eq "ActiveTimeSeries") { $value = 2000000 }
            $point = @{ timeStamp = "2026-11-25T18:30:00Z"; $aggregation = $value }
            $olderValue = if ($metricName -like "*Limit") { 3000000 } elseif ($metricName -eq "EventsPerMinuteIngestedPercentUtilization") { 115 } else { $value }
            $olderPoint = @{ timeStamp = "2026-11-25T18:29:00Z"; $aggregation = $olderValue }
            $zeroPoint = @{ timeStamp = "2026-11-25T18:30:00Z"; $aggregation = $(if ($metricName -like "*Limit") { 3000000 } else { 0 }) }
            $metrics += @{
                name = @{ value = $metricName }
                timeseries = @(
                    @{ metadatavalues = @(@{ name = @{ value = "StampColor" }; value = "blue" }); data = @($olderPoint, $point, @{ timeStamp = "2026-11-25T18:31:00Z" }) },
                    @{ metadatavalues = @(@{ name = @{ value = "StampColor" }; value = "green" }); data = @($zeroPoint) }
                )
            }
            if ($state.Scenario -eq "workspace-metrics") {
                $metrics[-1].timeseries = @(@{ metadatavalues = @(); data = @($olderPoint, $point, @{ timeStamp = "2026-11-25T18:31:00Z" }) })
            }
        }
        Write-FixtureJson @{ value = $metrics }
    }
    else { throw "Unexpected Azure command: $command" }
}

function kubectl {
    $command = $args -join " "
    $state.Calls.Add("kubectl $command")
    $global:LASTEXITCODE = 0
    if ($command -like "* get nodes") {
        if ($state.Scenario -eq "cluster-failure") { $global:LASTEXITCODE = 1; "Forbidden" } else { "test-node Ready" }
    }
    elseif ($command -like "* get pods -n kube-system -o json") {
        if ($state.Scenario -eq "pods-failure") { $global:LASTEXITCODE = 1; "Forbidden"; return }
        if ($state.Scenario -eq "absent") { '{"items":[]}'; return }
        Write-FixtureJson @{ items = @(
            @{ metadata = @{ name = "ama-metrics-test" }; spec = @{ containers = @(@{ name = "prometheus-collector" }) }; status = @{
                phase = "Running"; conditions = @(@{ type = "Ready"; status = "True" })
                containerStatuses = @(@{ name = "prometheus-collector"; ready = $true; restartCount = 1; state = @{ running = @{} }; lastState = @{ terminated = @{ reason = "OOMKilled" } } })
            } },
            @{ metadata = @{ name = "ama-metrics-ksm-test" }; spec = @{ containers = @(@{ name = "kube-state-metrics" }) }; status = @{
                phase = "Pending"; conditions = @(@{ type = "Ready"; status = "False" })
            } },
            @{ metadata = @{ name = "unrelated-pod" }; spec = @{ containers = @(@{ name = "unrelated" }) }; status = @{ phase = "Running" } }
        ) }
    }
    elseif ($command -like "* logs ama-metrics-test *") {
        if ($state.Scenario -eq "logs-denied") { $global:LASTEXITCODE = 1; "Forbidden"; return }
        "2026-11-25T18:00:00Z WARNING throttled"
        "2026-11-25T18:00:01Z ERROR fixture scrape failure"
    }
    elseif ($command -like "* exec -i ama-metrics-test *") {
        "Container search report"
        "### Searching /MetricsExtensionConsoleDebugLog.log"
        "MATCH /MetricsExtensionConsoleDebugLog.log:7:ERROR fixture remote-write failure"
    }
    elseif ($command -like "* exec ama-metrics-test *") {
        "CONFIG ROOT: /opt/microsoft/otelcollector"
        "collector-config.yml"
        "DIAGNOSTIC LOG: /MetricsExtensionConsoleDebugLog.log"
        "ERROR fixture remote-write failure"
    }
    elseif ($command -like "* get configmap *") {
        if ($state.Scenario -eq "configmaps-failure") { $global:LASTEXITCODE = 1; "Forbidden"; return }
        if ($state.Scenario -ne "absent" -and $command -like "* configmap ama-metrics-settings-configmap *") {
            if ($command -like "* -o json") {
                Write-FixtureJson @{ data = @{ "cluster-metrics" = "default-targets-scrape-enabled: |-`n  kubelet = true`nminimal-ingestion-profile: |-`n  enabled = true`n" } }
                return
            }
            "apiVersion: v1`nkind: ConfigMap`nmetadata:`n  name: ama-metrics-settings-configmap`ndata:`n  settings: |-`n    enabled = true"
        }
    }
    elseif ($command -like "* get crd *") {
        if ($state.Scenario -ne "absent") {
            "apiVersion: apiextensions.k8s.io/v1`nkind: CustomResourceDefinition`nmetadata:`n  name: fixture"
        }
    }
    elseif ($command -like "* get podmonitors.azmonitoring.coreos.com *" -or $command -like "* get servicemonitors.azmonitoring.coreos.com *") {
        if ($command -like "* -o json") {
            if ($state.Scenario -eq "no-monitors") { '{"items":[]}'; return }
            '{"items":[{"metadata":{"name":"fixture-monitor","namespace":"fixture"}}]}'
            return
        }
        "apiVersion: v1`nkind: List`nitems:`n- apiVersion: azmonitoring.coreos.com/v1`n  metadata:`n    name: fixture-monitor`n    namespace: fixture"
    }
    else { throw "Unexpected kubectl command: $command" }
}

try {
    $scenarios = @("success", "gui-confirmation", "workspace-metrics", "absent", "no-monitors", "not-associated", "default-only-ampls", "workspace-only-ampls",
        "decline-azure", "login-failure", "subscription-failure", "decline-cluster", "missing-kubectl",
        "credentials-failure", "cluster-failure", "pods-failure", "configmaps-failure", "association-denied",
        "dcr-denied", "dce-denied", "metrics-denied", "no-metrics", "logs-denied")
    foreach ($scenario in $scenarios) {
        $state.Scenario = $scenario
        $state.Calls.Clear()
        $state.Prompts.Clear()
        $outputRoot = Join-Path $testRoot $scenario
        $failure = $null
        try {
            & $collector -AksResourceId $clusterId -MonitorWorkspaceResourceId $workspaceId -OutputRoot $outputRoot `
                -ConfirmAuthentication:($scenario -eq "gui-confirmation") *> $null
        }
        catch { $failure = $_ }
        $shouldStop = $scenario -notin @("success", "gui-confirmation", "workspace-metrics", "absent", "no-monitors", "not-associated", "default-only-ampls", "workspace-only-ampls")
        if ($null -ne $failure -and -not $shouldStop) {
            Get-ChildItem -LiteralPath $outputRoot -Filter "collection-issues.txt" -Recurse | ForEach-Object {
                Write-Host (Get-Content -LiteralPath $_.FullName -Raw)
            }
        }
        Assert-True (($null -ne $failure) -eq $shouldStop) "Unexpected completion for $scenario : $failure"
        $run = Get-ChildItem -LiteralPath $outputRoot -Directory | Select-Object -First 1
        $files = @(Get-ChildItem -LiteralPath $run.FullName -File)
        Assert-True (@($files | Where-Object { $_.Name -match 'account-show|aks-show|monitor-workspace|aks-authentication|aks-get-credentials|kube-system-pods|account-set' }).Count -eq 0) "Unwanted raw context/authentication artifact persisted."
        $summaryFile = Join-Path $run.FullName "report-summary.md"
        $fatalAuth = $scenario -in @("decline-azure", "login-failure", "subscription-failure", "decline-cluster", "missing-kubectl", "credentials-failure", "cluster-failure", "pods-failure")
        if ($fatalAuth) {
            Assert-True (-not (Test-Path $summaryFile)) "A success summary was generated after $scenario."
            if ($scenario -eq "decline-azure") { Assert-True ($state.Calls.Count -eq 0) "Azure was called after decline." }
            if ($scenario -eq "login-failure") { Assert-True ($state.Calls.Count -eq 1) "Continued after failed login." }
            if ($scenario -eq "subscription-failure") { Assert-True ($state.Calls.Count -eq 2) "Continued after failed subscription selection." }
            if ($scenario -eq "missing-kubectl") { Assert-True ($failure.Exception.Message -like "*kubectl not found*az aks install-cli*") "Missing kubectl guidance." }
            if ($scenario -in @("decline-cluster", "missing-kubectl", "credentials-failure")) {
                Assert-True (-not ($state.Calls -match "^kubectl")) "kubectl ran without credentials/consent."
            }
            if ($scenario -eq "cluster-failure") {
                Assert-True (-not ($state.Calls -match "az rest")) "Collected resource evidence before verifying cluster."
            }
        }
        else {
            $summary = Get-Content -LiteralPath $summaryFile -Raw
            $amplsText = Get-Content (Join-Path $run.FullName "ampls-association.txt") -Raw
            $dcr = Get-Content (Join-Path $run.FullName "04-dcr-list.txt") -Raw | ConvertFrom-Json
            $dce = Get-Content (Join-Path $run.FullName "05-dce-list.txt") -Raw | ConvertFrom-Json
            $ingestionText = Get-Content (Join-Path $run.FullName "ingestion-status.txt") -Raw
            Assert-True (-not (@($files | Where-Object { $_.Extension -in @(".json", ".yaml", ".log") }).Count)) "Non-text evidence file persisted."
            Assert-True (Test-Path (Join-Path $run.FullName "evidence-report.txt")) "Missing combined evidence report."
            Assert-True ((Get-Content (Join-Path $run.FullName "evidence-report.txt") -Raw).Contains("FILE: ingestion-status.txt")) "Combined report is missing evidence files."
            Assert-True ($summary.Contains("Workspace public network access: Disabled")) "Missing workspace public access summary."
            Assert-True (-not ($state.Calls -match "data-collection rule list|private-link-scope list| get configmap -n")) "Used broad resource-group/configmap collection."
            if ($shouldStop) {
                Assert-True ($summary.Contains("Collection status: Incomplete")) "Failure was reported as complete."
            }
            if ($scenario -eq "workspace-metrics") {
                Assert-True ($ingestionText.Contains("Events per minute [workspace]") -and $ingestionText.Contains("Active time series [workspace]")) "Workspace metric series were lost."
                Assert-True (([regex]::Matches($ingestionText, "Status: Measured")).Count -eq 2) "Unfiltered workspace metrics were not reported."
                Assert-True (([regex]::Matches($ingestionText, "Limit \(latest\): 2000000")).Count -eq 2 -and $ingestionText -like "*(2 samples)*") "Lost quota or samples from unfiltered workspace metrics."
            }
            if ($scenario -in @("success", "gui-confirmation")) {
                Assert-True ($dcr.resources.Count -eq 2 -and $dce.resources.Count -eq 2) "Did not resolve cross-group associations and workspace defaults."
                Assert-True (@($dcr.resources | Where-Object { $_.id -eq $dcrId }).Count -eq 1) "Missing linked DCR JSON."
                Assert-True (@($dce.resources | Where-Object { $_.id -eq $fixtureDceId }).Count -eq 1) "Missing linked DCE JSON."
                Assert-True ($amplsText -like "*Status: Associated*" -and $amplsText.Contains($amplsId)) "Wrong AMPLS ARM ID."
                $eventsBlock = Get-IngestionBlock $ingestionText "Events per minute [StampColor=blue]"
                $seriesBlock = Get-IngestionBlock $ingestionText "Active time series [StampColor=blue]"
                Assert-True ($ingestionText.Contains("Events per minute [StampColor=green]")) "Lost a dimension."
                Assert-True ($eventsBlock -match "Limit \(latest\): 2000000" -and $eventsBlock -match "Usage \(latest\): 2020000" -and $eventsBlock -match "Utilization % \(latest\): 101 " -and $eventsBlock -match "Peak utilization %: 115" -and $eventsBlock -match "exceeded \(>100%\) in observed samples: Yes") "Incorrect current limit, usage, peak or exceedance."
                Assert-True ($seriesBlock -match "Utilization % \(latest\): 100 " -and $seriesBlock -match "exceeded \(>100%\) in observed samples: No" -and $seriesBlock -match "reached \(>=100%\) in observed samples: Yes") "Incorrect 100 percent boundary."
                Assert-True ($ingestionText -match "Limit \(latest\): 3000000" -and $ingestionText -match "Utilization % \(latest\): 0 ") "Lost zero metric values or merged dimensions."
                Assert-True ($eventsBlock -match "Utilization % \(latest\): 101 at 2026-11-25T18:30:00Z") "Null sample replaced last real measurement."
                Assert-True ($eventsBlock -match "\*" -and $eventsBlock -match "one-minute samples" -and $eventsBlock -match "18:30 UTC|18:29 UTC") "Ingestion section is not a line chart."
                $status = Get-Content (Join-Path $run.FullName "ama-metrics-status.txt") -Raw
                Assert-True ($status -like "*ama-metrics-test*" -and $status -notlike "*unrelated-pod*" -and $status -like "*ama-metrics-ksm-test*") "Status includes unrelated pods or drops unready containers."
                Assert-True ($status -like "*OOMKilled*") "Lost prior termination reason."
                Assert-True (Test-Path (Join-Path $run.FullName "ama-metrics-test-prometheus-collector-previous.txt")) "Missing prior collector logs."
                Assert-True ($state.Calls -contains "kubectl --context test-aks --request-timeout=60s logs ama-metrics-test -c prometheus-collector -n kube-system") "Logs were not collected with the plain kubectl logs format."
                Assert-True (@($state.Calls | Where-Object { $_ -like "*logs ama-metrics-test*" -and ($_ -match "--since|--tail|--timestamps") }).Count -eq 0) "Log command has extra options."
                Assert-True (@($state.Calls | Where-Object { $_ -like "*exec -i ama-metrics-test -c prometheus-collector -n kube-system -- /bin/bash" }).Count -eq 1) "Did not enter the container with /bin/bash."
                Assert-True ((Get-Content (Join-Path $run.FullName "ama-metrics-test-container-search.txt") -Raw) -like "*ERROR fixture remote-write failure*") "Missing in-container search output."
                Assert-True ((Get-Content (Join-Path $run.FullName "collector-files.txt") -Raw) -like "*collector-config.yml*") "Missing in-container file collection."
                $issues = Get-Content (Join-Path $run.FullName "ama-metrics-errors-warnings.txt") -Raw
                Assert-True ($issues -like "*WARNING throttled*" -and $issues -like "*(inside container)*fixture remote-write failure*") "Missing warning/error excerpts."
                Assert-True (Test-Path (Join-Path $run.FullName "ama-metrics-settings-configmap.txt")) "Missing readable ConfigMap content."
                Assert-True ((Get-Content (Join-Path $run.FullName "configmaps-status.txt") -Raw) -like "*ama-metrics-prometheus-config: Not present*") "Missing optional ConfigMap absence status."
                Assert-True (Test-Path (Join-Path $run.FullName "podmonitors.azmonitoring.coreos.com.txt")) "Missing monitor content."
                if ($scenario -eq "gui-confirmation") { Assert-True ($state.Prompts.Count -eq 0) "GUI still needs console confirmation." }
                $reportText = Get-Content (Join-Path $run.FullName "technical-report.txt") -Raw
                $reportHtml = Get-Content (Join-Path $run.FullName "technical-report.html") -Raw
                Assert-True ($reportText.Contains("1. EXECUTIVE SUMMARY") -and $reportText.Contains("ENVIRONMENT") -and $reportText.Contains("5. RECOMMENDED TROUBLESHOOTING ORDER")) "Technical report is missing sections."
                Assert-True ($reportText.Contains("[CRITICAL] prometheus-collector was OOMKilled in pod ama-metrics-test") -and $reportText.Contains("[CRITICAL] Ingestion limit reached: Events per minute")) "Technical report is missing the issues found."
                Assert-True ($reportText.Contains("Minimal ingestion profile is enabled") -and $reportText.Contains("canadacentral")) "Technical report is missing configuration or environment details."
                Assert-True ($reportText.Contains("https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-troubleshoot") -and $reportText.Contains("kubectl describe pod ama-metrics-test -n kube-system")) "Technical report lacks official documentation or troubleshooting steps."
                Assert-True ($reportHtml.Contains("data:image/png;base64,") -and @($files | Where-Object { $_.Name -like "ingestion-*.png" }).Count -ge 2) "Ingestion charts are not embedded as images in the technical report."
                Assert-True ((Get-Content (Join-Path $run.FullName "evidence-report.txt") -Raw).Contains("FILE: technical-report.txt")) "Combined report omits the technical report."
            }
            if ($scenario -eq "absent") {
                Assert-True ($dcr.status -eq "NotConfigured" -and $dce.status -eq "NotConfigured") "Absent resources not explicit."
                Assert-True ($amplsText -like "*Status: NotAssociated*") "Absent AMPLS not explicit."
                Assert-True ((Get-Content (Join-Path $run.FullName "monitors-status.txt") -Raw) -like "*CRD not installed*") "CRD absence not explicit."
                Assert-True (-not ($state.Calls -match " --all-namespaces")) "Queried uninstalled CRDs."
            }
            if ($scenario -eq "no-monitors") {
                Assert-True ((Get-Content (Join-Path $run.FullName "monitors-status.txt") -Raw) -like "*no custom-resource instances found*") "Empty monitor lists not explicitly reported."
                Assert-True (-not (Test-Path (Join-Path $run.FullName "podmonitors.azmonitoring.coreos.com.txt"))) "Saved an empty monitor-content file."
            }
            if ($scenario -eq "not-associated") { Assert-True ($amplsText -like "*Status: NotAssociated*") "Empty links not reported as not associated." }
            if ($scenario -eq "default-only-ampls") {
                Assert-True ($amplsText -like "*Status: Associated*") "Destination workspace ingestion DCE was not checked."
            }
            if ($scenario -eq "workspace-only-ampls") {
                Assert-True ($amplsText -like "*Status: NotAssociated*" -and $amplsText -like "*AMPLS resource IDs: None*") "Unrelated workspace defaults were treated as a cluster association."
            }
            if ($scenario -in @("association-denied", "dcr-denied", "dce-denied")) {
                Assert-True ($amplsText -notlike "*Status: NotAssociated*" -and $amplsText -like "*Verification complete: False*") "Access failure reported as no AMPLS or as fully verified."
            }
            if ($scenario -in @("no-metrics", "metrics-denied")) {
                Assert-True ((Get-Content (Join-Path $run.FullName "technical-report.txt") -Raw).Contains("Ingestion metric unavailable")) "Technical report treats missing metrics as healthy."
                Assert-True (([regex]::Matches($ingestionText, "Status: Unknown")).Count -eq 2 -and $ingestionText -notlike "*Status: Measured*" -and $ingestionText -like "*No samples returned*") "Missing metrics treated as zero/healthy."
            }
        }
        Write-Host "PASS: $scenario"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Collector has syntax errors."
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Invoke-Tool" }, $true)
    Invoke-Expression $definition.Extent.Text
    $success = Invoke-Tool $env:ComSpec @("/d", "/c", "exit 0")
    Assert-True $success.Success "Empty successful output was treated as failure."
    $failure = Invoke-Tool $env:ComSpec @("/d", "/c", "exit 17")
    Assert-True (-not $failure.Success -and $failure.Error.Contains("Exit code: 17")) "Native exit code was lost."
    $warning = Invoke-Tool $env:ComSpec @("/d", "/c", "echo 123 & echo fixture-warning 1>&2")
    Assert-True ($warning.Success -and $warning.Text.Trim() -eq "123") "stderr contaminated successful JSON/stdout."
    Write-Host "PASS: native exit codes, empty output, and separate stderr"
    $snapshotAssignment = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq "snapshotScript"
    }, $true)
    $shellScript = Invoke-Expression $snapshotAssignment.Right.Extent.Text
    $argumentFixture = Join-Path $testRoot "argument-fixture.ps1"
    [System.IO.File]::WriteAllText($argumentFixture, 'param([string]$Payload); [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Payload))')
    $roundTrip = Invoke-Tool powershell @("-NoProfile", "-File", $argumentFixture, "-Payload", $shellScript)
    Assert-True $roundTrip.Success "Native snapshot-script argument transfer failed."
    $received = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($roundTrip.Text.Trim()))
    Assert-True ($received -ceq $shellScript) "Snapshot shell quoting/newlines changed during native invocation."
    Write-Host "PASS: collector snapshot native argument quoting"
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
