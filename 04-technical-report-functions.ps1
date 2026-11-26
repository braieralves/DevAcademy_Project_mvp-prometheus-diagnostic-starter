# Functions that turn collected evidence into a technical report (HTML with embedded charts + plain text).
# Dot-sourced by 03-prometheus-evidence-collection.ps1; relies on its Get-Value helper.

$script:DocCatalog = [ordered]@{
    troubleshoot    = @{ Title = "Troubleshoot collection of Prometheus metrics in Azure Monitor"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-troubleshoot" }
    overview        = @{ Title = "Overview of Azure Monitor with Prometheus"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/prometheus-metrics-overview" }
    enable          = @{ Title = "Enable Monitoring for Azure Kubernetes Service (AKS) Clusters"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-enable" }
    scrapeConfig    = @{ Title = "Customize scraping of Prometheus metrics in Azure Monitor using ConfigMap"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-configuration" }
    scrapeDefault   = @{ Title = "Default Prometheus metrics configuration in Azure Monitor (includes the minimal ingestion profile)"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-default" }
    scrapeValidate  = @{ Title = "Create custom Prometheus scrape job from your Kubernetes cluster using ConfigMap"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-validate" }
    scrapeCrd       = @{ Title = "Create custom Prometheus scrape job from your Kubernetes cluster using CRDs"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/prometheus-metrics-scrape-crd" }
    ingestLimits    = @{ Title = "Monitor Azure Monitor workspace metrics ingestion"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-monitor-ingest-limits" }
    serviceLimits   = @{ Title = "Azure Monitor service limits (Prometheus metrics)"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/service-limits" }
    workspaceMetrics = @{ Title = "Supported metrics - Microsoft.Monitor/accounts"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/reference/supported-metrics/microsoft-monitor-accounts-metrics" }
    workspace       = @{ Title = "Azure Monitor workspace overview"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-overview" }
    privateEndpoint = @{ Title = "Use private endpoints for Managed Prometheus and Azure Monitor workspaces"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/metrics/azure-monitor-workspace-private-endpoint" }
    privateLink     = @{ Title = "Enable private link for monitoring virtual machines and Kubernetes clusters in Azure Monitor"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/containers/kubernetes-monitoring-private-link" }
    dce             = @{ Title = "Data collection endpoints in Azure Monitor"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-endpoint-overview" }
    dcr             = @{ Title = "Data Collection Rules in Azure Monitor"; Url = "https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/data-collection-rule-overview" }
    httpProxy       = @{ Title = "Configure Azure Kubernetes Service (AKS) nodes with an HTTP proxy"; Url = "https://learn.microsoft.com/en-us/azure/aks/http-proxy" }
    egress          = @{ Title = "Outbound Network and FQDN Rules for Azure Kubernetes Service (AKS) Clusters"; Url = "https://learn.microsoft.com/en-us/azure/aks/outbound-rules-control-egress" }
}

function Limit-ReportText {
    param([string]$Text, [int]$Length = 260)
    if ($null -eq $Text) { return "" }
    $clean = ($Text -replace '\s+', ' ').Trim()
    if ($clean.Length -gt $Length) { return $clean.Substring(0, $Length) + "..." }
    return $clean
}

function ConvertTo-ReportSlug {
    param([string]$Text)
    $slug = ($Text -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if (-not $slug) { return "series" }
    return $slug
}

function Format-ReportNumber {
    param([AllowNull()]$Value, [string]$Unit = "")
    if ($null -eq $Value) { return "Unknown" }
    $number = [double]$Value
    if ($Unit -eq "%") { return $number.ToString("0.0", [cultureinfo]::InvariantCulture) + "%" }
    if ([math]::Abs($number) -ge 1000) { return $number.ToString("N0", [cultureinfo]::InvariantCulture) }
    return $number.ToString("0.##", [cultureinfo]::InvariantCulture)
}

function Add-ChartPanel {
    param($Graphics, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$Title, [object[]]$Series, [string]$Unit, [double]$FixedMax = [double]::NaN)
    $font = New-Object System.Drawing.Font("Segoe UI", 9)
    $boldFont = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(225, 225, 225), 1)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 150, 150), 1)
    $rightAlign = New-Object System.Drawing.StringFormat
    $rightAlign.Alignment = [System.Drawing.StringAlignment]::Far
    $centerAlign = New-Object System.Drawing.StringFormat
    $centerAlign.Alignment = [System.Drawing.StringAlignment]::Center
    $pens = @()
    try {
        $left = 95; $right = 20; $top = 36; $bottom = 28
        $px = $X + $left; $py = $Y + $top; $pw = $W - $left - $right; $ph = $H - $top - $bottom
        $Graphics.DrawString($Title, $boldFont, [System.Drawing.Brushes]::Black, [single]$X, [single]($Y + 4))
        $allPoints = @($Series | ForEach-Object { $_.Points } | Where-Object { $null -ne $_ })
        if ($allPoints.Count -eq 0) {
            $Graphics.DrawRectangle($borderPen, $px, $py, $pw, $ph)
            $Graphics.DrawString("No samples returned (Unknown, not zero).", $font, [System.Drawing.Brushes]::DimGray, [single]($px + 10), [single]($py + 10))
            return
        }
        $ticks = @($allPoints | ForEach-Object { ([datetime]$_.Timestamp).ToUniversalTime().Ticks })
        $tMin = ($ticks | Measure-Object -Minimum).Minimum
        $tMax = ($ticks | Measure-Object -Maximum).Maximum
        if ($tMax -le $tMin) { $tMax = $tMin + 1 }
        $values = @($allPoints | ForEach-Object { [double]$_.Value })
        $yMin = 0.0
        $yMax = if ([double]::IsNaN($FixedMax)) { ($values | Measure-Object -Maximum).Maximum * 1.1 } else { $FixedMax }
        if ($yMax -le $yMin) { $yMax = 1.0 }
        for ($i = 0; $i -le 4; $i++) {
            $yy = $py + $ph - ($ph * $i / 4)
            $Graphics.DrawLine($gridPen, [single]$px, [single]$yy, [single]($px + $pw), [single]$yy)
            $label = Format-ReportNumber ($yMin + ($yMax - $yMin) * $i / 4) $Unit
            $Graphics.DrawString($label, $font, [System.Drawing.Brushes]::DimGray, (New-Object System.Drawing.RectangleF([single]($X), [single]($yy - 8), [single]($left - 6), [single]16)), $rightAlign)
            $xx = $px + $pw * $i / 4
            $tick = [datetime]::new([long]($tMin + ($tMax - $tMin) * $i / 4), [System.DateTimeKind]::Utc)
            $Graphics.DrawString($tick.ToString("HH:mm"), $font, [System.Drawing.Brushes]::DimGray, (New-Object System.Drawing.RectangleF([single]($xx - 30), [single]($py + $ph + 4), [single]60, [single]16)), $centerAlign)
        }
        $Graphics.DrawRectangle($borderPen, $px, $py, $pw, $ph)
        $legendX = $px + $pw
        foreach ($s in @($Series | Where-Object { @($_.Points).Count -gt 0 })) {
            $pen = New-Object System.Drawing.Pen($s.Color, 2.5)
            if ($s.Dash) { $pen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dash }
            $pens += $pen
            $points = @($s.Points | Sort-Object Timestamp | ForEach-Object {
                $t = ([datetime]$_.Timestamp).ToUniversalTime().Ticks
                $v = [math]::Max($yMin, [math]::Min($yMax, [double]$_.Value))
                New-Object System.Drawing.PointF([single]($px + $pw * ($t - $tMin) / ($tMax - $tMin)), [single]($py + $ph - $ph * ($v - $yMin) / ($yMax - $yMin)))
            })
            if ($points.Count -ge 2) { $Graphics.DrawLines($pen, [System.Drawing.PointF[]]$points) }
            else { $Graphics.DrawEllipse($pen, $points[0].X - 3, $points[0].Y - 3, 6, 6) }
            $size = $Graphics.MeasureString($s.Name, $font)
            $legendX = $legendX - $size.Width - 24
            $Graphics.DrawLine($pen, [single]$legendX, [single]($Y + 12), [single]($legendX + 16), [single]($Y + 12))
            $Graphics.DrawString($s.Name, $font, [System.Drawing.Brushes]::Black, [single]($legendX + 20), [single]($Y + 4))
        }
    }
    finally {
        foreach ($pen in $pens) { $pen.Dispose() }
        $font.Dispose(); $boldFont.Dispose(); $gridPen.Dispose(); $borderPen.Dispose(); $rightAlign.Dispose(); $centerAlign.Dispose()
    }
}

# Draws a two-panel PNG: usage over time and utilization % against the 100% limit.
function New-IngestionChartImage {
    param([string]$Path, [string]$Title, [string]$LimitText, [object[]]$Usage, [object[]]$Percent, [double]$PercentMax = 100)
    Add-Type -AssemblyName System.Drawing
    $width = 1000; $height = 680
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $titleFont = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $noteFont = New-Object System.Drawing.Font("Segoe UI", 9)
    $blue = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $red = [System.Drawing.Color]::FromArgb(209, 52, 56)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $graphics.Clear([System.Drawing.Color]::White)
        $graphics.DrawString($Title, $titleFont, [System.Drawing.Brushes]::Black, [single]20, [single]12)
        $usageSeries = @(@{ Name = "Usage (max per minute)"; Color = $blue; Dash = $false; Points = @($Usage) })
        Add-ChartPanel -Graphics $graphics -X 20 -Y 50 -W 960 -H 290 -Title "Usage - limit: $LimitText" -Series $usageSeries -Unit ""
        $thresholdPoints = @()
        $all = @($Percent | Sort-Object Timestamp)
        if ($all.Count -gt 0) {
            $thresholdPoints = @([pscustomobject]@{ Timestamp = $all[0].Timestamp; Value = 100 }, [pscustomobject]@{ Timestamp = $all[-1].Timestamp; Value = 100 })
        }
        $percentSeries = @(
            @{ Name = "Utilization % (average per minute)"; Color = $blue; Dash = $false; Points = @($Percent) },
            @{ Name = "100% limit"; Color = $red; Dash = $true; Points = $thresholdPoints }
        )
        Add-ChartPanel -Graphics $graphics -X 20 -Y 350 -W 960 -H 290 -Title "Utilization of the limit" -Series $percentSeries -Unit "%" -FixedMax $PercentMax
        $graphics.DrawString("Source: Azure Monitor workspace platform metrics, one-minute samples, time in UTC. Missing samples are Unknown, not zero.", $noteFont, [System.Drawing.Brushes]::DimGray, [single]20, [single]650)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $titleFont.Dispose(); $noteFont.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}

function ConvertTo-ReportHtml {
    param([object[]]$Blocks, [string]$Title)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><title>$(& $enc $Title)</title><style>")
    [void]$sb.AppendLine("body{font-family:Segoe UI,Arial,sans-serif;max-width:1040px;margin:24px auto;padding:0 16px;color:#1b1b1b;line-height:1.5}h1{border-bottom:3px solid #0078d4;padding-bottom:6px}h2{margin-top:32px;border-bottom:1px solid #ccc;padding-bottom:4px}h3{margin-bottom:4px}table{border-collapse:collapse;width:100%;margin:8px 0}th,td{border:1px solid #d0d0d0;padding:5px 8px;text-align:left;vertical-align:top;font-size:14px;word-break:break-word}th{background:#f0f4f8}pre{background:#f6f8fa;border:1px solid #ddd;padding:10px;overflow:auto;font-size:13px}code{font-family:Consolas,monospace}img{max-width:100%;border:1px solid #ddd;margin:6px 0}.sev{display:inline-block;padding:1px 8px;border-radius:3px;color:#fff;font-size:12px;font-weight:600;margin-right:6px}.Critical{background:#d13438}.Warning{background:#c27a00}.Info{background:#0078d4}.cap{color:#555;font-size:13px;margin-top:0}.callout{background:#eef6fc;border-left:4px solid #0078d4;padding:8px 12px;margin:10px 0}")
    [void]$sb.AppendLine("</style></head><body>")
    foreach ($b in $Blocks) {
        switch ($b.Type) {
            "h1" { [void]$sb.AppendLine("<h1>$(& $enc $b.Text)</h1>") }
            "h2" { [void]$sb.AppendLine("<h2>$(& $enc $b.Text)</h2>") }
            "h3" {
                $badge = if ($b["Severity"]) { "<span class='sev $($b["Severity"])'>$(& $enc $b["Severity"].ToUpper())</span>" } else { "" }
                [void]$sb.AppendLine("<h3>$badge$(& $enc $b.Text)</h3>")
            }
            "p" { [void]$sb.AppendLine("<p>$(& $enc $b.Text)</p>") }
            "callout" { [void]$sb.AppendLine("<div class='callout'>$(& $enc $b.Text)</div>") }
            "bullets" {
                [void]$sb.AppendLine("<ul>")
                foreach ($i in $b.Items) { [void]$sb.AppendLine("<li>$(& $enc $i)</li>") }
                [void]$sb.AppendLine("</ul>")
            }
            "steps" {
                [void]$sb.AppendLine("<ol>")
                foreach ($i in $b.Items) { [void]$sb.AppendLine("<li>$(& $enc $i)</li>") }
                [void]$sb.AppendLine("</ol>")
            }
            "code" { [void]$sb.AppendLine("<pre><code>$(& $enc $b.Text)</code></pre>") }
            "kv" {
                [void]$sb.AppendLine("<table>")
                foreach ($r in $b.Rows) { [void]$sb.AppendLine("<tr><th style='width:28%'>$(& $enc $r[0])</th><td>$(& $enc $r[1])</td></tr>") }
                [void]$sb.AppendLine("</table>")
            }
            "table" {
                [void]$sb.AppendLine("<table><tr>" + (($b.Headers | ForEach-Object { "<th>$(& $enc $_)</th>" }) -join "") + "</tr>")
                foreach ($r in $b.Rows) { [void]$sb.AppendLine("<tr>" + (($r | ForEach-Object { "<td>$(& $enc $_)</td>" }) -join "") + "</tr>") }
                [void]$sb.AppendLine("</table>")
            }
            "img" {
                if ($b.Path -and (Test-Path -LiteralPath $b.Path)) {
                    $data = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($b.Path))
                    [void]$sb.AppendLine("<img alt='$(& $enc $b.Alt)' src='data:image/png;base64,$data'>")
                }
                else { [void]$sb.AppendLine("<p><em>Chart image unavailable. See ingestion-status.txt for the text line charts.</em></p>") }
                [void]$sb.AppendLine("<p class='cap'>$(& $enc $b.Caption)</p>")
            }
            "links" {
                [void]$sb.AppendLine("<ul>")
                foreach ($l in $b.Items) { [void]$sb.AppendLine("<li><a href='$(& $enc $l.Url)'>$(& $enc $l.Title)</a><br><small>$(& $enc $l.Url)</small></li>") }
                [void]$sb.AppendLine("</ul>")
            }
        }
    }
    [void]$sb.AppendLine("</body></html>")
    return $sb.ToString()
}

function ConvertTo-ReportText {
    param([object[]]$Blocks)
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($b in $Blocks) {
        switch ($b.Type) {
            "h1" { $lines.Add($b.Text.ToUpper()); $lines.Add("=" * [math]::Min(100, $b.Text.Length)); $lines.Add("") }
            "h2" { $lines.Add(""); $lines.Add($b.Text.ToUpper()); $lines.Add("-" * [math]::Min(100, $b.Text.Length)); $lines.Add("") }
            "h3" { $lines.Add(""); $lines.Add($(if ($b["Severity"]) { "[$($b["Severity"].ToUpper())] $($b.Text)" } else { $b.Text })); $lines.Add("") }
            "p" { $lines.Add($b.Text); $lines.Add("") }
            "callout" { $lines.Add(">> $($b.Text)"); $lines.Add("") }
            "bullets" { foreach ($i in $b.Items) { $lines.Add("  * $i") }; $lines.Add("") }
            "steps" { $n = 1; foreach ($i in $b.Items) { $lines.Add("  $n. $i"); $n++ }; $lines.Add("") }
            "code" { foreach ($l in ($b.Text -split '\r?\n')) { $lines.Add("    $l") }; $lines.Add("") }
            "kv" { foreach ($r in $b.Rows) { $lines.Add(("  {0,-34} {1}" -f $r[0], $r[1])) }; $lines.Add("") }
            "table" {
                $widths = @(0..($b.Headers.Count - 1) | ForEach-Object {
                    $c = $_
                    (@($b.Headers[$c]) + @($b.Rows | ForEach-Object { [string]$_[$c] }) | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum
                })
                $format = { param($cells) "  " + ((0..($cells.Count - 1) | ForEach-Object { ([string]$cells[$_]).PadRight($widths[$_]) }) -join "  ") }
                $lines.Add((& $format $b.Headers).TrimEnd())
                $lines.Add("  " + (($widths | ForEach-Object { "-" * $_ }) -join "  "))
                foreach ($r in $b.Rows) { $lines.Add((& $format $r).TrimEnd()) }
                $lines.Add("")
            }
            "img" {
                $lines.Add("  [Chart image: $($b.File)] $($b.Caption)")
                $lines.Add("  The same data is drawn as text line charts in ingestion-status.txt.")
                $lines.Add("")
            }
            "links" { foreach ($l in $b.Items) { $lines.Add("  * $($l.Title)"); $lines.Add("    $($l.Url)") }; $lines.Add("") }
        }
    }
    return ($lines -join "`r`n")
}

function Get-ReportSettings {
    param([AllowNull()]$ConfigMap, [AllowNull()][string]$CustomConfigText)
    $result = @{ EnabledTargets = @(); DisabledTargets = @(); MinimalIngestion = $null; DebugMode = $null; CustomJobs = @(); CustomTargets = @() }
    $data = Get-Value $ConfigMap "data"
    if ($null -ne $data) {
        $all = (@($data.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join "`n")
        $clusterProperty = $data.PSObject.Properties["cluster-metrics"]
        $cluster = if ($null -ne $clusterProperty) { [string]$clusterProperty.Value } else { $all }
        $block = [regex]::Match($cluster, 'default-targets-scrape-enabled:\s*\|-?\s*\r?\n((?:[ \t]+[\w-]+[ \t]*=[ \t]*(?:true|false)[ \t]*(?:\r?\n|$))+)')
        if ($block.Success) {
            foreach ($m in [regex]::Matches($block.Groups[1].Value, '([\w-]+)\s*=\s*(true|false)')) {
                if ($m.Groups[2].Value -eq "true") { $result.EnabledTargets += $m.Groups[1].Value } else { $result.DisabledTargets += $m.Groups[1].Value }
            }
        }
        $minimal = [regex]::Match($cluster, 'minimal-ingestion-profile:\s*\|-?\s*\r?\n\s*enabled\s*=\s*(true|false)')
        if ($minimal.Success) { $result.MinimalIngestion = ($minimal.Groups[1].Value -eq "true") }
        $debug = [regex]::Match($all, 'debug-mode(?:\s*=\s*|:\s*\|-?\s*\r?\n\s*enabled\s*=\s*)(true|false)')
        if ($debug.Success) { $result.DebugMode = ($debug.Groups[1].Value -eq "true") }
    }
    if ($CustomConfigText) {
        $result.CustomJobs = @([regex]::Matches($CustomConfigText, '(?m)^\s*-?\s*job_name:\s*[''"]?([^\s''"]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $result.CustomTargets = @([regex]::Matches($CustomConfigText, '(?m)^\s*-\s+[''"]?([A-Za-z0-9._-]+:\d+)[''"]?\s*$') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    }
    return $result
}

function Get-ReportLogSignatures {
    # Order matters: the first signature that matches a line claims it, so harmless startup noise is listed first.
    return @(
        @{ Id = "backpressure"; Severity = "Info"; Pattern = '\[BackPressure\]'
           Title = "Metrics Extension back-pressure settings (informational)"
           Impact = "Printed by Metrics Extension at startup. It is not by itself workspace throttling; compare with the ingestion utilization charts in this report."
           Steps = @("Treat as informational unless the ingestion charts show utilization near 100% or the logs report HTTP 429 responses.") ; Docs = @("ingestLimits", "troubleshoot") },
        @{ Id = "proxy"; Severity = "Info"; Pattern = 'Invalid proxy'
           Title = "Metrics Extension reports an invalid proxy URL (empty proxy setting)"
           Impact = "Usually harmless startup noise when the cluster does not use an HTTP proxy. It matters only if the nodes are expected to reach Azure through a proxy."
           Steps = @("If the cluster uses an HTTP proxy, confirm the proxy settings and that the proxy allows the Azure Monitor endpoints.", "If no proxy is used, no action is needed for this message.")
           Docs = @("httpProxy", "egress") },
        @{ Id = "startup"; Severity = "Info"; Pattern = '(ImdsInfoLoader|LocationIdProvider|Autopilot|Pilotfish|DNS cache|systemctl|IMDS|MetricsExtensionConfigurationLoader)'
           Title = "Metrics Extension startup messages (IMDS, location id, DNS cache, configuration dump)"
           Impact = "These messages are emitted while the agent probes its environment and loads its configuration at startup and are not, by themselves, evidence that metrics are being dropped."
           Steps = @("Treat as informational unless the same messages are accompanied by authentication, throttling or network errors.") ; Docs = @("troubleshoot") },
        @{ Id = "auth"; Severity = "Critical"; Pattern = '(?i)(unauthorized|forbidden|AuthorizationFailed|status(code)?[ :=]+(401|403)|No configuration present for the AKS resource|invalid_client|AADSTS\d+)'
           Title = "Authentication or authorization failure while sending metrics"
           Impact = "If the collector cannot authenticate to the Azure Monitor workspace or has no configuration for the cluster, no metrics are ingested."
           Steps = @("Check the addon-token-adapter container logs for authentication errors: kubectl logs <ama-metrics pod> -n kube-system -c addon-token-adapter",
                     "Confirm the Data Collection Rule, Data Collection Endpoint and Azure Monitor workspace exist and are linked to the cluster.",
                     "The troubleshooting guide lists a private AKS cluster linked to an Azure Monitor Private Link Scope as an unsupported cause of 'No configuration present for the AKS resource'.")
           Docs = @("troubleshoot", "dcr", "enable") },
        @{ Id = "throttle"; Severity = "Critical"; Pattern = '(?i)(status(code)?[ :=]+429|too many requests|rate.?limit|ingest\w*.*throttl|throttl\w*.*(ingest|quota exceeded|limit exceeded))'
           Title = "Ingestion throttling reported by the collector"
           Impact = "Throttled data is rejected, which appears as missing metrics or gaps."
           Steps = @("Compare with the ingestion charts in this report; both utilization metrics should stay below 100%.", "Reduce series volume (keep lists, minimal ingestion, scrape interval) or request a quota increase for the Azure Monitor workspace.")
           Docs = @("ingestLimits", "serviceLimits", "troubleshoot") },
        @{ Id = "config"; Severity = "Critical"; Pattern = '(?i)(unmarshal|yaml: |error loading config|invalid scrape|unknown field|failed to (load|parse|validate)|config(uration)? (is )?invalid)'
           Title = "Scrape configuration could not be parsed or validated"
           Impact = "An invalid custom configuration can prevent the custom scrape jobs from loading, so their metrics are missing."
           Steps = @("Check the config-reader container logs: kubectl logs <ama-metrics-operator-targets pod> -n kube-system -c config-reader",
                     "Verify the ConfigMap is named ama-metrics-prometheus-config in kube-system and the config sits under data.prometheus-config.",
                     "Validate the custom scrape job before applying it.")
           Docs = @("troubleshoot", "scrapeValidate", "scrapeConfig") },
        @{ Id = "network"; Severity = "Warning"; Pattern = '(?i)(no such host|dial tcp|connection refused|i/o timeout|context deadline exceeded|TLS handshake|x509|network is unreachable)'
           Title = "Network, DNS or TLS errors while scraping or sending data"
           Impact = "The collector may not reach a scrape target, or may not reach the Azure Monitor ingestion endpoint (firewall, DNS, private link or proxy)."
           Steps = @("Identify whether the failing address is a scrape target (see the Prometheus UI targets page) or an Azure Monitor endpoint.",
                     "For Azure Monitor endpoints, verify the egress rules and, when private link is used, DNS resolution of the Data Collection Endpoint from the nodes.",
                     "For scrape targets, verify the service, endpoints and port are reachable from the collector pod.")
           Docs = @("egress", "privateEndpoint", "troubleshoot") },
        @{ Id = "scrape"; Severity = "Warning"; Pattern = '(?i)(scrape.*(fail|error)|server returned HTTP status|target.*(down|unreachable))'
           Title = "Scrape failures for one or more targets"
           Impact = "Targets that fail to scrape report up=0 and produce no metrics."
           Steps = @("Port-forward to the collector pod and open the targets page to see the exact scrape error per target: kubectl port-forward <ama-metrics pod> -n kube-system 9090, then browse 127.0.0.1:9090/targets.")
           Docs = @("troubleshoot", "scrapeValidate") },
        @{ Id = "export"; Severity = "Warning"; Pattern = '(?i)(failed to (export|send|publish|upload)|export(ing)? failed|dropp(ed|ing) (data|metric|series|samples))'
           Title = "Failures exporting or dropping metrics"
           Impact = "Exported samples that fail or are dropped do not reach the workspace."
           Steps = @("Look for the matching error text in the prometheus-collector log and the MetricsExtension log, and check authentication, throttling and network findings first.")
           Docs = @("troubleshoot") },
        @{ Id = "limits"; Severity = "Warning"; Pattern = '(?i)(label (name|value).*(length|exceed)|too many labels|duplicate label|exceeds? (the )?limit)'
           Title = "Metric, label name or label value limits exceeded"
           Impact = "Per the troubleshooting guide, when label or label-value limits are exceeded the entire scrape job can fail and its metrics are dropped."
           Steps = @("Check the targets page for up=0 and its error message and reduce label count or length on the affected job.")
           Docs = @("troubleshoot") }
    )
}

function Get-ReportFindings {
    param($Context)
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($Severity, $Title, $Evidence, $Impact, $Steps, $Docs)
        $findings.Add([pscustomobject]@{ Severity = $Severity; Order = $findings.Count; Title = $Title; Evidence = @($Evidence); Impact = $Impact; Steps = @($Steps); Docs = @($Docs) })
    }
    $aksName = $Context.AksName; $aksRg = $Context.AksResourceGroup; $sub = $Context.SubscriptionId
    $pod = if ($Context.ReplicaPod) { $Context.ReplicaPod } else { "<ama-metrics pod>" }

    if ($Context.StatusRows.Count -eq 0) {
        & $add "Critical" "No ama-metrics pods were found in kube-system" @("0 ama-metrics pods returned by the Kubernetes API.") `
            "Without the collector pods nothing scrapes or sends Prometheus metrics." `
            @("Confirm managed Prometheus is enabled on the cluster: az aks show -g $aksRg -n $aksName --query azureMonitorProfile",
              "Enable it if needed: az aks update --enable-azure-monitor-metrics -g $aksRg -n $aksName --azure-monitor-workspace-resource-id <workspace-resource-id>",
              "Check for admission policies or node problems that block the ama-metrics deployments: kubectl get deploy,ds -n kube-system | findstr ama-metrics") @("enable", "troubleshoot")
    }
    if ($null -ne $Context.Aks -and (Get-Value $Context.Aks "properties.azureMonitorProfile.metrics.enabled") -eq $false) {
        & $add "Critical" "Managed Prometheus is not enabled on the AKS cluster" @("azureMonitorProfile.metrics.enabled = false") `
            "The metrics add-on is disabled, so no collector or data collection rule association is maintained." `
            @("Enable it: az aks update --enable-azure-monitor-metrics -g $aksRg -n $aksName --azure-monitor-workspace-resource-id <workspace-resource-id>") @("enable")
    }
    if ($Context.AssociationsSucceeded -and $Context.ClusterDcrIds.Count -eq 0) {
        & $add "Critical" "The cluster has no Data Collection Rule association" @("0 data collection rule associations were returned for the AKS resource.") `
            "Without an association the collector has no destination workspace configuration, so nothing is ingested." `
            @("List associations: az monitor data-collection rule association list --resource $($Context.AksId)",
              "Re-run the enablement command so the DCR and DCE are created and associated: az aks update --enable-azure-monitor-metrics -g $aksRg -n $aksName --azure-monitor-workspace-resource-id <workspace-resource-id>",
              "Confirm the DCR targets the Azure Monitor workspace and uses the Microsoft-PrometheusMetrics stream.") @("dcr", "enable", "troubleshoot")
    }
    $dcePublicDisabled = @($Context.Dces | Where-Object { (Get-Value $_ "properties.networkAcls.publicNetworkAccess") -eq "Disabled" })
    $publicDisabled = $Context.NetworkAccess -eq "Disabled" -or $dcePublicDisabled.Count -gt 0
    $disabledWhere = @(); if ($Context.NetworkAccess -eq "Disabled") { $disabledWhere += "Azure Monitor workspace" }; if ($dcePublicDisabled.Count) { $disabledWhere += "data collection endpoint(s): " + (($dcePublicDisabled | ForEach-Object { ($_.id -split '/')[-1] }) -join ", ") }
    if ($publicDisabled -and $Context.AmplsStatus -eq "NotAssociated") {
        & $add "Critical" "Public network access is disabled but the cluster is not linked to an Azure Monitor Private Link Scope" @("Public access disabled on: $($disabledWhere -join '; ')", "AMPLS association: NotAssociated") `
            "Ingestion over the public path is blocked and there is no private path, so the collector cannot deliver metrics." `
            @("Either allow public network access on the workspace/DCE, or link the DCE to an AMPLS and make the cluster resolve the private endpoint.", "Verify from a node or pod that the DCE ingestion endpoint resolves and is reachable.") @("privateEndpoint", "privateLink", "dce")
    }
    elseif ($publicDisabled -and $Context.AmplsStatus -eq "Unknown") {
        & $add "Warning" "Public network access is disabled and private-link association could not be verified" @("Public access disabled on: $($disabledWhere -join '; ')", "AMPLS association: Unknown (evidence incomplete)") `
            "If no private path exists, ingestion is blocked." @("Resolve the collection issues listed in this report, then rerun the collector.") @("privateEndpoint", "privateLink")
    }
    elseif ($Context.AmplsStatus -eq "Associated") {
        $evidence = @("AMPLS: $($Context.AmplsIds -join ', ')")
        $steps = @("Verify the Data Collection Endpoint ingestion hostname resolves to a private IP from the cluster nodes (private DNS zones linked to the cluster VNet).", "Check the AMPLS access mode and that the workspace and DCE are in the scope.")
        $severity = "Info"; $title = "Ingestion uses Azure Monitor Private Link"
        if ($null -ne $Context.Aks -and (Get-Value $Context.Aks "properties.apiServerAccessProfile.enablePrivateCluster") -eq $true) {
            $severity = "Warning"; $title = "Private AKS cluster is linked to an Azure Monitor Private Link Scope"
            $evidence += "AKS enablePrivateCluster = true"
            $steps += "The troubleshooting guide lists this combination as a cause of 'No configuration present for the AKS resource'. Review it with the private link documentation."
        }
        & $add $severity $title $evidence "A broken private DNS or access-mode setup would block ingestion even when everything else is healthy." $steps @("privateEndpoint", "privateLink", "troubleshoot")
    }

    foreach ($row in @($Context.StatusRows | Where-Object { $_.Container -eq "prometheus-collector" })) {
        $reasons = ($row.PreviousState + " " + $row.State)
        if ($reasons -match 'OOMKilled') {
            & $add "Critical" "prometheus-collector was OOMKilled in pod $($row.Pod)" @("Restarts: $($row.Restarts)", "Last state: $(Limit-ReportText $row.PreviousState 160)") `
                "The collector cannot keep up with the volume of metrics, so data is lost around each restart." `
                @("Describe the pod: kubectl describe pod $($row.Pod) -n kube-system", "Reduce volume (keep lists, minimal ingestion, scrape interval) or follow the scale recommendations.") @("troubleshoot", "scrapeConfig")
        }
    }
    $notReady = @($Context.StatusRows | Where-Object { $_.Ready -ne $true -and $_.Container -eq "prometheus-collector" })
    if ($notReady.Count) {
        & $add "Critical" "$($notReady.Count) prometheus-collector container(s) are not Ready" @($notReady | ForEach-Object { "$($_.Pod): phase $($_.Phase), state $(Limit-ReportText $_.State 120)" }) `
            "Containers that are not Ready are not scraping or exporting." `
            @("kubectl describe pod <pod> -n kube-system", "kubectl logs <pod> -n kube-system -c prometheus-collector") @("troubleshoot")
    }
    $restarted = @($Context.StatusRows | Where-Object { [int]$_.Restarts -gt 0 -and $_.Container -eq "prometheus-collector" -and ($_.PreviousState + $_.State) -notmatch 'OOMKilled' })
    if ($restarted.Count) {
        & $add "Warning" "$($restarted.Count) prometheus-collector container(s) restarted" @($restarted | ForEach-Object { "$($_.Pod): $($_.Restarts) restart(s), previous state $(Limit-ReportText $_.PreviousState 140)" }) `
            "The guide says restarts should equal the number of ConfigMap changes applied; additional restarts need an explanation." `
            @("kubectl describe pod <pod> -n kube-system", "kubectl logs <pod> -n kube-system -c prometheus-collector --previous") @("troubleshoot")
    }

    $otherRestarted = @($Context.StatusRows | Where-Object { [int]$_.Restarts -gt 0 -and $_.Container -ne "prometheus-collector" })
    if ($otherRestarted.Count) {
        & $add "Info" "$($otherRestarted.Count) other ama-metrics container(s) restarted" @($otherRestarted | ForEach-Object { "$($_.Pod) / $($_.Container): $($_.Restarts) restart(s), previous state $(Limit-ReportText $_.PreviousState 140)" }) `
            "Restarts are expected after ConfigMap or custom resource changes (the operator pod can have one extra at start). Repeated restarts of the target allocator can delay discovery of PodMonitor/ServiceMonitor targets." `
            @("kubectl describe pod <pod> -n kube-system to see the last termination reason and exit code.", "kubectl logs <pod> -n kube-system -c <container> --previous") @("troubleshoot", "scrapeCrd")
    }

    foreach ($row in $Context.Ingestion) {
        $r = $row.Row
        $label = "$($r.metric) [$($r.dimension)]"
        if ($r.status -eq "Unknown") {
            & $add "Warning" "Ingestion metric unavailable: $label" @("Usage, limit or utilization samples were not returned.") `
                "Ingestion headroom cannot be confirmed; Unknown is not zero." @("Verify the account has Monitoring Reader on the Azure Monitor workspace and rerun.") @("ingestLimits", "workspaceMetrics")
        }
        elseif ($null -ne $r.peakUtilizationPercent -and $r.peakUtilizationPercent -ge 100) {
            & $add "Critical" "Ingestion limit reached: $label" @("Peak utilization $(Format-ReportNumber $r.peakUtilizationPercent '%'); limit $(Format-ReportNumber $r.latestLimit)") `
                "At or above 100% the workspace throttles ingestion, which shows up as missing metrics." `
                @("Reduce active series or event rate, or request a quota increase (Support Request on the Azure Monitor workspace).", "Set an alert on the utilization metrics.") @("ingestLimits", "serviceLimits", "troubleshoot")
        }
        elseif ($null -ne $r.peakUtilizationPercent -and $r.peakUtilizationPercent -ge 80) {
            & $add "Warning" "Ingestion is approaching its limit: $label" @("Peak utilization $(Format-ReportNumber $r.peakUtilizationPercent '%'); limit $(Format-ReportNumber $r.latestLimit)") `
                "Little headroom remains before throttling." @("Review series growth and set an alert before 100%.") @("ingestLimits", "serviceLimits")
        }
    }
    $measured = @($Context.Ingestion | Where-Object { $_.Row.status -eq "Measured" })
    if ($measured.Count -and -not @($Context.Ingestion | Where-Object { $_.Row.status -eq "Unknown" -or ($null -ne $_.Row.peakUtilizationPercent -and $_.Row.peakUtilizationPercent -ge 80) }).Count) {
        & $add "Info" "Workspace ingestion limits are not the cause" @($measured | ForEach-Object { "$($_.Row.metric): peak $(Format-ReportNumber $_.Row.peakUtilizationPercent '%') of limit $(Format-ReportNumber $_.Row.latestLimit)" }) `
            "Within the observed hour, neither limit was approached, so throttling by the workspace is unlikely to explain missing data." @("Continue with scrape configuration and target health.") @("ingestLimits")
    }

    $lines = @($Context.IssueLines | Where-Object { $_ -notmatch 'AggregatedDiagnosticInfoLogger|No matching error/warning' })
    $unclaimed = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) { $unclaimed.Add([string]$line) }

    # Scrape failures logged by the collector name the job, target and reason, so report them per target.
    $scrapeLines = @($unclaimed | Where-Object { $_ -match 'Failed to scrape Prometheus endpoint' })
    if ($scrapeLines.Count) {
        foreach ($h in $scrapeLines) { [void]$unclaimed.Remove($h) }
        $failures = @{}
        foreach ($h in $scrapeLines) {
            $err = ([regex]::Match($h, '"error":"((?:[^"\\]|\\.)*)"').Groups[1].Value) -replace '\\"', '"'
            $job = [regex]::Match($h, 'job=\\"([^\\"]+)\\"').Groups[1].Value
            $instance = [regex]::Match($h, 'instance=\\"([^\\"]+)\\"').Groups[1].Value
            if (-not $instance) { $instance = [regex]::Match($err, 'https?://([^/"\s]+)').Groups[1].Value }
            if (-not $job) { $job = "(not in captured line)" }
            $namespace = [regex]::Match($h, 'namespace=\\"([^\\"]+)\\"').Groups[1].Value
            $key = "$job|$instance|$err"
            if (-not $failures.ContainsKey($key)) { $failures[$key] = [pscustomobject]@{ Job = $job; Instance = $instance; Namespace = $namespace; Error = $err; Count = 0 } }
            $failures[$key].Count++
        }
        $groups = @($failures.Values | Sort-Object Count -Descending)
        $evidence = @("$($scrapeLines.Count) failed scrape(s) logged for $($groups.Count) distinct target/error combination(s).") +
            @($groups | Select-Object -First 8 | ForEach-Object { "job '$($_.Job)', instance '$($_.Instance)': $(Limit-ReportText $_.Error 200) [$($_.Count) occurrence(s) in captured lines]" })
        $namespaces = @($groups | Where-Object { $_.Namespace } | ForEach-Object { $_.Namespace } | Select-Object -Unique)
        foreach ($g in $groups) { if (-not $g.Namespace -and $g.Instance -match '^([^.:]+)\.([^.:]+)\.svc') { $namespaces += $Matches[2] } }
        $namespaces = @($namespaces | Select-Object -Unique)
        $steps = @("Open the Prometheus UI targets page to see each failing target: kubectl port-forward $pod -n kube-system 9090, then browse 127.0.0.1:9090/targets (and /service-discovery to confirm the target was discovered).")
        $namespaceList = if ($namespaces.Count) { $namespaces } else { @("<namespace>") }
        foreach ($ns in $namespaceList) { $steps += "Inspect the workloads behind the failing targets in namespace ${ns}: kubectl get pods,svc,endpoints -n $ns" }
        $errorText = ($groups | ForEach-Object { $_.Error }) -join " "
        if ($errorText -match 'connection refused') { $steps += "Connection refused: the name resolves but nothing accepts connections on that port. Confirm the exporter/application pod is Running, listens on that port, and that the Service port and targetPort match (kubectl get endpoints <service> -n <namespace> must list pod IPs)." }
        if ($errorText -match 'HTTP status 404') { $steps += "HTTP 404: the endpoint answers but not at the scraped path. Check metrics_path (default /metrics) and the port in the scrape job or PodMonitor/ServiceMonitor, and that the application really exposes Prometheus metrics there (an exporter may be required)." }
        if ($errorText -match 'no such host') { $steps += "No such host: the DNS name does not exist. Check the Service name and namespace in the target." }
        if ($errorText -match '(timeout|deadline exceeded)') { $steps += "Timeouts: check network policies between kube-system and the target, and whether scrape_timeout is long enough." }
        if ($errorText -match 'HTTP status (401|403)') { $steps += "401/403: the endpoint requires authentication; configure authorization in the scrape job." }
        $steps += "After fixing the target, confirm it shows UP on the targets page and that up{job=`"<job>`"} is 1 in the workspace."
        & $add "Critical" "Scrape targets are failing, so their metrics are missing" $evidence `
            "A target that cannot be scraped reports up=0 and produces no metrics. This is a direct cause of missing metrics for those jobs." $steps @("troubleshoot", "scrapeValidate", "scrapeCrd")
    }
    foreach ($signature in Get-ReportLogSignatures) {
        $hits = @($unclaimed | Where-Object { $_ -match $signature.Pattern })
        if ($hits.Count -eq 0) { continue }
        foreach ($h in $hits) { [void]$unclaimed.Remove($h) }
        $normalized = @($hits | ForEach-Object { ($_ -replace '\d{4}[-/]\d\d[-/]\d\d[T ][\d:.]+Z?', '' -replace 'TID:\d+', '' -replace '^\S+ \(inside container\): MATCH \S+?:\d+:', '' -replace '^\S+ \(previous\): ', '' -replace '^\S+?: ', '').Trim() } | Sort-Object -Unique)
        $podsHit = @($hits | ForEach-Object { ($_ -split '[ :]', 2)[0] } | Sort-Object -Unique)
        $evidence = @("$($hits.Count) matching line(s) across $($podsHit.Count) pod(s).") + @($normalized | Select-Object -First 3 | ForEach-Object { Limit-ReportText $_ 240 })
        & $add $signature.Severity $signature.Title $evidence $signature.Impact $signature.Steps $signature.Docs
    }
    if ($unclaimed.Count) {
        $other = @($unclaimed | ForEach-Object { ($_ -replace '\d{4}[-/]\d\d[-/]\d\d[T ][\d:.]+Z?', '' -replace 'TID:\d+', '') } | Sort-Object -Unique)
        & $add "Info" "Other error/warning/fail messages to review manually" (@("$($unclaimed.Count) line(s), $($other.Count) distinct message(s).") + @($other | Select-Object -First 4 | ForEach-Object { Limit-ReportText $_ 240 })) `
            "These did not match a known signature; they may be benign." @("Search the full text in evidence-report.txt and the <pod>-container-search.txt files.") @("troubleshoot")
    }

    $settings = $Context.Settings
    if ($settings.MinimalIngestion -eq $true) {
        & $add "Info" "Minimal ingestion profile is enabled for the default scrape targets" @("minimal-ingestion-profile enabled = true in ama-metrics-settings-configmap") `
            "Default targets then send only a curated list of metrics; other metrics from those targets are dropped by design. This is a common reason a specific metric is missing." `
            @("If the missing metric belongs to a default target (kubelet, cAdvisor, kube-state-metrics, node-exporter, ...), check the list of metrics kept by the minimal profile.", "Add the metric with the default-targets-metrics-keep-list setting or set minimal-ingestion-profile enabled = false, then watch ingestion utilization.") @("scrapeDefault", "scrapeConfig")
    }
    if ($settings.CustomJobs.Count) {
        $replicaCommand = "kubectl port-forward $pod -n kube-system 9090"
        & $add "Info" "Custom scrape job(s) are configured: $($settings.CustomJobs -join ', ')" @($settings.CustomTargets | ForEach-Object { "Target: $_" }) `
            "Custom jobs are scraped by the replica (cluster-level) collector. If their metrics are missing the job may not load, the target may not be discovered, or the endpoint may not answer." `
            @("Confirm the job is loaded: $replicaCommand, then open 127.0.0.1:9090/config and 127.0.0.1:9090/targets (health, last scrape, error).",
              "Check the target itself, for example: kubectl get svc,endpoints -A | findstr <service-name> and curl the metrics path from a debug pod.",
              "Check config-reader logs for parsing errors: kubectl logs <ama-metrics-operator-targets pod> -n kube-system -c config-reader",
              "Check relabel_configs do not filter out the target.") @("scrapeValidate", "troubleshoot", "scrapeConfig")
    }
    if ($settings.DebugMode -eq $false) {
        & $add "Info" "Debug mode is off" @("debug-mode = false") `
            "With debug mode off you cannot inspect the exact metrics the collector scrapes." `
            @("For a short investigation only, enable debug mode in the settings ConfigMap, then: kubectl port-forward $pod -n kube-system 9091 and browse 127.0.0.1:9091/metrics. Disable it afterwards because it can affect performance.") @("troubleshoot", "scrapeConfig")
    }
    if ($Context.ExpectedMetric) {
        & $add "Info" "Expected metric to verify: $($Context.ExpectedMetric)" @("Metric name provided for this investigation.") `
            "Determines which scrape job and filter should produce the series." `
            @("Identify the job that exposes it (default target or custom job) and confirm that job is up in the Prometheus UI targets page.", "Check it is not removed by minimal ingestion, a keep list or relabeling.", "Query it in the workspace with PromQL, e.g. count({__name__=`"$($Context.ExpectedMetric)`"}).") @("scrapeDefault", "troubleshoot")
    }
    if ($Context.CollectionIssues.Count) {
        & $add "Warning" "Some evidence could not be collected" @($Context.CollectionIssues | Select-Object -First 5 | ForEach-Object { Limit-ReportText $_ 260 }) `
            "Findings that depend on the missing evidence are shown as Unknown rather than healthy." `
            @("Check the signed-in account has read access to the cluster, workspace, DCRs and DCEs, then rerun the collector.") @("troubleshoot")
    }
    return @($findings | Sort-Object @{ Expression = { switch ($_.Severity) { "Critical" { 0 } "Warning" { 1 } default { 2 } } } }, Order)
}

function New-TechnicalReport {
    param($Context, [string]$OutDir)
    $findings = @(Get-ReportFindings $Context)
    $blocks = [System.Collections.Generic.List[object]]::new()
    $critical = @($findings | Where-Object { $_.Severity -eq "Critical" })
    $warnings = @($findings | Where-Object { $_.Severity -eq "Warning" })
    $infos = @($findings | Where-Object { $_.Severity -eq "Info" })

    $blocks.Add(@{ Type = "h1"; Text = "Technical Report - Azure Managed Prometheus Metrics Collection" })
    $blocks.Add(@{ Type = "kv"; Rows = @(
        @("Generated (UTC)", $Context.GeneratedUtc),
        @("AKS cluster", $Context.AksId),
        @("Azure Monitor workspace", $Context.WorkspaceId),
        @("Expected metric", $(if ($Context.ExpectedMetric) { $Context.ExpectedMetric } else { "not provided" })),
        @("Collection status", $Context.CompletionStatus)) })

    $blocks.Add(@{ Type = "h2"; Text = "1. Executive summary" })
    $verdict = if ($critical.Count) { "Most probable cause: $($critical[0].Title)." }
        elseif ($warnings.Count) { "No definitive fault was found. The most relevant warning is: $($warnings[0].Title)." }
        else { "No blocking fault was detected in the collected evidence. The remaining candidates are scrape configuration and target health (see the findings)." }
    $blocks.Add(@{ Type = "callout"; Text = $verdict })
    $blocks.Add(@{ Type = "p"; Text = "Findings: $($critical.Count) critical, $($warnings.Count) warning, $($infos.Count) informational. Absence of an error is not proof of health: unknown evidence is reported as Unknown." })
    $blocks.Add(@{ Type = "bullets"; Items = @($findings | ForEach-Object { "[$($_.Severity)] $($_.Title)" }) })

    $blocks.Add(@{ Type = "h2"; Text = "2. Environment" })
    $blocks.Add(@{ Type = "h3"; Text = "AKS cluster" })
    $aks = $Context.Aks
    $pools = if ($aks) { @(Get-Value $aks "properties.agentPoolProfiles" | ForEach-Object { "$($_.name): $($_.count) x $($_.vmSize) ($($_.osType), $($_.mode))" }) -join "; " } else { "Unknown" }
    $aksRows = @(
        @("Name", $Context.AksName), @("Resource group", $Context.AksResourceGroup), @("Subscription", $Context.SubscriptionId),
        @("Location", $(if ($aks) { [string](Get-Value $aks "location") } else { "Unknown (AKS resource not readable)" })),
        @("Kubernetes version", $(if ($aks) { [string](Get-Value $aks "properties.kubernetesVersion") } else { "Unknown" })),
        @("Pricing tier", $(if ($aks) { [string](Get-Value $aks "sku.tier") } else { "Unknown" })),
        @("Network plugin / dataplane", $(if ($aks) { "$(Get-Value $aks 'properties.networkProfile.networkPlugin') / $(Get-Value $aks 'properties.networkProfile.networkDataplane')" } else { "Unknown" })),
        @("Outbound type", $(if ($aks) { [string](Get-Value $aks "properties.networkProfile.outboundType") } else { "Unknown" })),
        @("Private cluster", $(if ($aks) { $(if ($null -eq (Get-Value $aks "properties.apiServerAccessProfile.enablePrivateCluster")) { "False (not set)" } else { [string](Get-Value $aks "properties.apiServerAccessProfile.enablePrivateCluster") }) } else { "Unknown" })),
        @("Managed Prometheus enabled", $(if ($aks) { [string](Get-Value $aks "properties.azureMonitorProfile.metrics.enabled") } else { "Unknown" })),
        @("Node pools", $pools))
    $blocks.Add(@{ Type = "kv"; Rows = $aksRows })

    $blocks.Add(@{ Type = "h3"; Text = "Monitoring pipeline (workspace, DCR, DCE, private link)" })
    $dcrNames = if ($Context.Dcrs.Count) { ($Context.Dcrs | ForEach-Object { "$(($_.id -split '/')[-1]) [$(((Get-Value $_ 'properties.dataFlows') | ForEach-Object { $_.streams }) -join ', ')]" }) -join "; " } else { "None resolved" }
    $dceNames = if ($Context.Dces.Count) { ($Context.Dces | ForEach-Object { "$(($_.id -split '/')[-1]) ($(Get-Value $_ 'properties.metricsIngestion.endpoint'); public access: $(Get-Value $_ 'properties.networkAcls.publicNetworkAccess'))" }) -join "; " } else { "None resolved" }
    $blocks.Add(@{ Type = "kv"; Rows = @(
        @("Azure Monitor workspace", $Context.WorkspaceName),
        @("Workspace location", [string](Get-Value $Context.Workspace "location")),
        @("Workspace public network access", $Context.NetworkAccess),
        @("Data collection rules", $dcrNames),
        @("Data collection endpoints", $dceNames),
        @("Cluster-associated DCR count", $(if ($Context.AssociationsSucceeded) { [string]$Context.ClusterDcrIds.Count } else { "Unknown" })),
        @("AMPLS association", "$($Context.AmplsStatus) $(if ($Context.AmplsIds.Count) { '(' + ($Context.AmplsIds -join ', ') + ')' })")) })

    $blocks.Add(@{ Type = "h3"; Text = "Collector pods (ama-metrics)" })
    $blocks.Add(@{ Type = "table"; Headers = @("Pod", "Container", "Phase", "Ready", "Restarts", "Previous state"); Rows = @($Context.StatusRows | ForEach-Object { ,@($_.Pod, $_.Container, $_.Phase, $_.Ready, $_.Restarts, $(if ($_.PreviousState -in @("{}", "null", "")) { "none" } else { Limit-ReportText $_.PreviousState 90 })) }) })

    $blocks.Add(@{ Type = "h3"; Text = "Scrape configuration" })
    $settings = $Context.Settings
    $blocks.Add(@{ Type = "kv"; Rows = @(
        @("Default targets enabled", $(if ($settings.EnabledTargets.Count) { $settings.EnabledTargets -join ", " } else { "Unknown / defaults" })),
        @("Default targets disabled", $(if ($settings.DisabledTargets.Count) { $settings.DisabledTargets -join ", " } else { "None" })),
        @("Minimal ingestion profile", $(if ($null -eq $settings.MinimalIngestion) { "Unknown" } else { [string]$settings.MinimalIngestion })),
        @("Debug mode", $(if ($null -eq $settings.DebugMode) { "Unknown" } else { [string]$settings.DebugMode })),
        @("Custom scrape jobs", $(if ($settings.CustomJobs.Count) { $settings.CustomJobs -join ", " } else { "None" })),
        @("Custom job targets", $(if ($settings.CustomTargets.Count) { $settings.CustomTargets -join ", " } else { "None" }))) })
    $blocks.Add(@{ Type = "bullets"; Items = @($Context.ConfigStatus + $Context.MonitorStatus) })

    $blocks.Add(@{ Type = "h2"; Text = "3. Workspace ingestion (last 60 minutes, UTC)" })
    $blocks.Add(@{ Type = "p"; Text = "The charts show usage and utilization of the Azure Monitor workspace ingestion limits. Utilization at or above 100% means throttling, a known cause of missing metrics." })
    foreach ($series in $Context.Ingestion) {
        $r = $series.Row
        $file = "ingestion-$(ConvertTo-ReportSlug $r.metric)-$(ConvertTo-ReportSlug $r.dimension).png"
        $path = Join-Path $OutDir $file
        $percentMax = if ($null -ne $r.peakUtilizationPercent -and $r.peakUtilizationPercent -gt 100) { [double]$r.peakUtilizationPercent * 1.05 } else { 100.0 }
        try {
            New-IngestionChartImage -Path $path -Title "$($r.metric) [$($r.dimension)]" -LimitText (Format-ReportNumber $r.latestLimit) -Usage $series.Usage -Percent $series.Percent -PercentMax $percentMax
        }
        catch { $path = $null; Write-Warning "Could not draw the ingestion chart image: $($_.Exception.Message)" }
        $blocks.Add(@{ Type = "h3"; Text = "$($r.metric) [$($r.dimension)] - status $($r.status)" })
        $blocks.Add(@{ Type = "img"; Path = $path; File = $file; Alt = "Line chart of $($r.metric)"; Caption = "Latest usage $(Format-ReportNumber $r.latestUsage) of limit $(Format-ReportNumber $r.latestLimit); latest utilization $(Format-ReportNumber $r.latestUtilizationPercent '%'); peak $(Format-ReportNumber $r.peakUtilizationPercent '%'); exceeded: $($r.exceededInObservedSamples); reached: $($r.reachedLimitInObservedSamples)." })
    }
    if (-not $Context.Ingestion.Count) { $blocks.Add(@{ Type = "p"; Text = "No ingestion metrics were collected." }) }

    $blocks.Add(@{ Type = "h2"; Text = "4. Findings" })
    $docKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $findings) {
        $blocks.Add(@{ Type = "h3"; Text = $f.Title; Severity = $f.Severity })
        $blocks.Add(@{ Type = "p"; Text = "Why it matters: $($f.Impact)" })
        $blocks.Add(@{ Type = "p"; Text = "Evidence:" })
        $blocks.Add(@{ Type = "bullets"; Items = $f.Evidence })
        $blocks.Add(@{ Type = "p"; Text = "Suggested troubleshooting:" })
        $blocks.Add(@{ Type = "steps"; Items = $f.Steps })
        $refs = @($f.Docs | Select-Object -Unique | ForEach-Object { "$($script:DocCatalog[$_].Title) - $($script:DocCatalog[$_].Url)" })
        if ($refs.Count) { $blocks.Add(@{ Type = "p"; Text = "Reference: " + ($refs -join " | ") }) }
        foreach ($k in $f.Docs) { if (-not $docKeys.Contains($k)) { $docKeys.Add($k) } }
    }

    $blocks.Add(@{ Type = "h2"; Text = "5. Recommended troubleshooting order" })
    $pod = if ($Context.ReplicaPod) { $Context.ReplicaPod } else { "<ama-metrics pod>" }
    $blocks.Add(@{ Type = "steps"; Items = @(
        "Fix every Critical finding first, then rerun this collector to confirm it is gone.",
        "Pods: kubectl get pods -n kube-system | findstr ama-metrics, then kubectl describe pod <pod> -n kube-system for restart reasons.",
        "Logs: kubectl logs $pod -n kube-system -c prometheus-collector (also -c config-reader, -c targetallocator and -c addon-token-adapter on the operator/replica pods).",
        "Targets: kubectl port-forward $pod -n kube-system 9090, then browse 127.0.0.1:9090/config, /service-discovery and /targets.",
        "Exact scraped metrics (short term only): enable debug mode, kubectl port-forward $pod -n kube-system 9091, browse 127.0.0.1:9091/metrics.",
        "Quota: in the Azure portal open the Azure Monitor workspace, Metrics, and check Active Time Series % Utilization and Events Per Minute Ingested % Utilization stay below 100%.",
        "If still unresolved, open a support request and attach evidence-report.txt (review and redact sensitive names first).") })

    $blocks.Add(@{ Type = "h2"; Text = "6. Evidence files" })
    $blocks.Add(@{ Type = "p"; Text = "evidence-report.txt contains every collected file in one text document. Individual files are in the same folder: report-summary.md, ingestion-status.txt, ama-metrics-status.txt, *-prometheus-collector.txt (kubectl logs), *-container-search.txt (kubectl exec ... /bin/bash search), ama-metrics-errors-warnings.txt, collector-files.txt, configmap and monitor files, DCR/DCE/AMPLS files, collection-issues.txt." })

    $blocks.Add(@{ Type = "h2"; Text = "7. Official Microsoft documentation" })
    $allKeys = @($docKeys) + @($script:DocCatalog.Keys | Where-Object { $_ -in @("troubleshoot", "overview", "ingestLimits", "scrapeConfig", "scrapeDefault") -and -not $docKeys.Contains($_) })
    $blocks.Add(@{ Type = "links"; Items = @($allKeys | Select-Object -Unique | ForEach-Object { $script:DocCatalog[$_] }) })

    return [pscustomobject]@{
        Html = ConvertTo-ReportHtml -Blocks $blocks -Title "Technical Report - Azure Managed Prometheus Metrics Collection"
        Text = ConvertTo-ReportText -Blocks $blocks
        Findings = $findings
    }
}
