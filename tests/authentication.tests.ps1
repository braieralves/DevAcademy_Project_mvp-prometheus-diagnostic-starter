$ErrorActionPreference = "Stop"
$collector = Join-Path $PSScriptRoot "..\03-prometheus-evidence-collection.ps1"
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("prom-auth-tests-" + [guid]::NewGuid())
$state = @{
    Scenario = ""
    Calls = [System.Collections.Generic.List[string]]::new()
    Prompts = [System.Collections.Generic.List[string]]::new()
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
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

function az {
    $command = $args -join " "
    $state.Calls.Add("az $command")
    $global:LASTEXITCODE = 0
    if ($command -like "login *") {
        if ($state.Scenario -eq "login-failure") {
            $global:LASTEXITCODE = 1
        }
    }
    elseif ($command -like "account set *") {
        if ($state.Scenario -eq "subscription-failure") {
            $global:LASTEXITCODE = 1
            "Subscription access denied"
        }
    }
    elseif ($command -like "account show *") { '{"id":"test-subscription"}' }
    elseif ($command -like "aks show *") { '{"id":"/subscriptions/test/resourceGroups/test/providers/Microsoft.ContainerService/managedClusters/test"}' }
    elseif ($command -like "aks get-credentials *") {
        if ($state.Scenario -eq "credentials-failure") {
            $global:LASTEXITCODE = 1
            "Credential access denied"
        }
    }
    elseif ($command -like "resource show *") { '{}' }
    elseif ($command -like "monitor *") { '[]' }
    else { throw "Unexpected Azure command: $command" }
}

function kubectl {
    $command = $args -join " "
    $state.Calls.Add("kubectl $command")
    $global:LASTEXITCODE = 0
    if ($command -eq "--context test-aks get nodes --request-timeout=60s" -and $state.Scenario -eq "cluster-failure") {
        $global:LASTEXITCODE = 1
        "Forbidden"
    }
    elseif ($command -eq "--context test-aks get nodes -o wide --request-timeout=60s" -and $state.Scenario -eq "nodes-failure") {
        $global:LASTEXITCODE = 1
        "Connection timed out"
    }
    elseif ($command -eq "--context test-aks get pods -n kube-system -o json --request-timeout=60s") {
        if ($state.Scenario -eq "pods-failure") {
            $global:LASTEXITCODE = 1
            "Forbidden"
        }
        else { '{"items":[]}' }
    }
    elseif ($command -eq "--context test-aks get configmap -n kube-system --request-timeout=60s" -and $state.Scenario -eq "configmaps-failure") {
        $global:LASTEXITCODE = 1
        "Forbidden"
    }
    else { "Read access OK" }
}

try {
    foreach ($scenario in @("success", "gui-confirmation", "decline-azure", "login-failure", "subscription-failure", "decline-cluster", "missing-kubectl", "credentials-failure", "cluster-failure", "nodes-failure", "pods-failure", "configmaps-failure")) {
        $state.Scenario = $scenario
        $state.Calls.Clear()
        $state.Prompts.Clear()
        $outputRoot = Join-Path $testRoot $scenario
        $failure = $null
        try {
            & $collector -SubscriptionId "test-subscription" -AksResourceGroup "test-aks-rg" `
                -AksClusterName "test-aks" -MonitorResourceGroup "test-monitor-rg" `
                -MonitorWorkspaceName "test-workspace" -OutputRoot $outputRoot `
                -ConfirmAuthentication:($scenario -eq "gui-confirmation") *> $null
        }
        catch { $failure = $_ }

        $shouldStop = $scenario -notin @("success", "gui-confirmation")
        Assert-True (($null -ne $failure) -eq $shouldStop) "Unexpected completion for $scenario : $failure"
        $summaryFile = @(Get-ChildItem -LiteralPath $outputRoot -Filter "report-summary.md" -Recurse)
        if ($shouldStop) {
            Assert-True ($summaryFile.Count -eq 0) "A success summary was generated after $scenario."
        }
        if ($scenario -eq "decline-azure") {
            Assert-True ($state.Calls.Count -eq 0) "Azure was called after sign-in was declined."
        }
        elseif ($scenario -eq "login-failure") {
            Assert-True ($state.Calls.Count -eq 1) "Collection continued after Azure login failed."
        }
        elseif ($scenario -eq "subscription-failure") {
            Assert-True ($state.Calls.Count -eq 2) "Collection continued after subscription selection failed."
        }
        elseif ($scenario -eq "decline-cluster") {
            Assert-True (-not ($state.Calls -match "get-credentials|kubectl")) "Cluster was accessed after confirmation was declined."
        }
        elseif ($scenario -eq "missing-kubectl") {
            Assert-True ($failure.Exception.Message -like "*kubectl not found*az aks install-cli*") "Missing kubectl did not provide installation guidance."
            Assert-True (@($state.Prompts -like "Connect to AKS*").Count -eq 1) "Cluster connection was not requested."
            Assert-True (-not ($state.Calls -match "get-credentials|kubectl")) "Cluster was accessed without kubectl."
        }
        elseif ($scenario -eq "credentials-failure") {
            Assert-True ($failure.Exception.Message -like "*Unable to retrieve AKS credentials*") "Credential failure was not surfaced."
            Assert-True (-not ($state.Calls -match "^kubectl")) "kubectl was called after credential retrieval failed."
        }
        elseif ($scenario -eq "cluster-failure") {
            Assert-True ($failure.Exception.Message -like "*Cluster authentication/access failed*") "Cluster access failure was not surfaced."
            Assert-True (-not ($state.Calls -match "az aks show")) "Evidence collection began without verified cluster access."
        }
        elseif ($scenario -in @("nodes-failure", "pods-failure", "configmaps-failure")) {
            Assert-True ($failure.Exception.Message -like "*Unable to query*Collection is incomplete*") "Failed Kubernetes queries were not surfaced."
        }
        else {
            Assert-True ($summaryFile.Count -eq 1) "Expected one summary for $scenario."
            $summary = Get-Content -LiteralPath $summaryFile[0].FullName -Raw
            Assert-True ($summary.Contains("AKS access verified (kubectl get nodes): True")) "Incorrect cluster authentication status for $scenario."
            Assert-True ($summary.Contains("Azure session authenticated: True")) "Azure authentication status missing."
            Assert-True ($state.Calls.Contains("az login --output none")) "Standard interactive Azure login was not requested."
            Assert-True ($state.Calls.Contains("az aks get-credentials -g test-aks-rg -n test-aks --context test-aks --overwrite-existing")) "Credentials were not loaded for the requested context."
            Assert-True ($state.Calls.Contains("kubectl --context test-aks get nodes --request-timeout=60s")) "Cluster access was not verified."
            Assert-True ($state.Calls.Contains("kubectl --context test-aks get pods -n kube-system -o json --request-timeout=60s")) "Kubernetes evidence was not collected."
            Assert-True ($state.Calls.IndexOf("kubectl --context test-aks get nodes --request-timeout=60s") -lt $state.Calls.IndexOf("az aks show -g test-aks-rg -n test-aks -o json")) "Cluster access was not verified before evidence collection."
            if ($scenario -eq "gui-confirmation") {
                Assert-True ($state.Prompts.Count -eq 0) "GUI confirmation still required console input."
            }
        }
        Write-Host "PASS: $scenario"
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($collector, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "Collector has syntax errors."
    foreach ($name in @("Save-Text", "Run-External")) {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        Invoke-Expression $definition.Extent.Text
    }
    $nativeOutput = Join-Path $testRoot "native-output.txt"
    $success = Run-External -Command '& $env:ComSpec /d /c "exit 0"' -OutputPath $nativeOutput
    Assert-True $success "A native command with empty output was treated as a failure."
    $success = Run-External -Command '& $env:ComSpec /d /c "exit 17"' -OutputPath $nativeOutput
    Assert-True (-not $success) "A nonzero native exit code was treated as success."
    Assert-True ((Get-Content $nativeOutput -Raw).Contains("Exit code: 17")) "Native failure exit code was not recorded."
    Write-Host "PASS: native empty output and nonzero exit code"
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
