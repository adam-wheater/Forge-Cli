. "$PSScriptRoot/TokenBudget.ps1"

$Global:MetricsSession = $null
$Global:MetricsEvents = @()

function Initialize-Metrics {
    [CmdletBinding()]
    param ()

    $Global:MetricsSession = @{
        SessionId = [guid]::NewGuid().ToString()
        StartTime = (Get-Date).ToUniversalTime()
        EndTime   = $null
    }
    $Global:MetricsEvents = @()

    Write-Host "Metrics session started: $($Global:MetricsSession.SessionId)"
}

function Add-MetricEvent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet("iteration_start", "iteration_end", "agent_call", "patch_generated", "test_run", "build_result", "cost_incurred")]
        [string]$Type,
        [Parameter(Mandatory)][hashtable]$Data
    )

    if (-not $Global:MetricsSession) {
        Write-Warning "Metrics not initialized. Call Initialize-Metrics first."
        return
    }

    $event = @{
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Type      = $Type
        Data      = $Data
    }

    $Global:MetricsEvents += $event
}

function Save-Metrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$OutputPath
    )

    if (-not $Global:MetricsSession) {
        Write-Warning "Metrics not initialized. Call Initialize-Metrics first."
        return
    }

    $Global:MetricsSession.EndTime = (Get-Date).ToUniversalTime()

    $totalTime = ($Global:MetricsSession.EndTime - $Global:MetricsSession.StartTime).TotalSeconds
    $totalTokens = Get-TotalTokens
    $costGBP = Get-CurrentCostGBP

    # Calculate iteration count
    $iterationStarts = ($Global:MetricsEvents | Where-Object { $_.Type -eq "iteration_start" }).Count
    $iterationEnds = ($Global:MetricsEvents | Where-Object { $_.Type -eq "iteration_end" }).Count
    $iterationsUsed = [Math]::Max($iterationStarts, $iterationEnds)

    # Calculate patches tried
    $patchesGenerated = ($Global:MetricsEvents | Where-Object { $_.Type -eq "patch_generated" }).Count

    # Calculate test results
    $testRuns = $Global:MetricsEvents | Where-Object { $_.Type -eq "test_run" }
    $testsFixed = 0
    foreach ($tr in $testRuns) {
        if ($tr.Data -and $tr.Data.ContainsKey("testsFixed")) {
            $testsFixed += [int]$tr.Data["testsFixed"]
        }
    }

    # Calculate build results
    $buildResults = $Global:MetricsEvents | Where-Object { $_.Type -eq "build_result" }
    $buildSuccesses = ($buildResults | Where-Object { $_.Data -and $_.Data["success"] -eq $true }).Count
    $buildFailures = ($buildResults | Where-Object { $_.Data -and $_.Data["success"] -eq $false }).Count

    # Calculate success rate
    $totalBuilds = $buildSuccesses + $buildFailures
    $successRate = if ($totalBuilds -gt 0) { [Math]::Round(($buildSuccesses / $totalBuilds) * 100, 1) } else { 0 }

    $metrics = @{
        sessionId      = $Global:MetricsSession.SessionId
        startTime      = $Global:MetricsSession.StartTime.ToString("o")
        endTime        = $Global:MetricsSession.EndTime.ToString("o")
        totalTimeSeconds = [Math]::Round($totalTime, 2)
        iterationsUsed = $iterationsUsed
        tokensConsumed = $totalTokens
        promptTokens   = $Global:PromptTokens
        completionTokens = $Global:CompletionTokens
        costGBP        = [Math]::Round($costGBP, 4)
        patchesTried   = $patchesGenerated
        testsFixed     = $testsFixed
        buildSuccesses = $buildSuccesses
        buildFailures  = $buildFailures
        successRate    = $successRate
        events         = $Global:MetricsEvents
    }

    try {
        $dir = Split-Path $OutputPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $metrics | ConvertTo-Json -Depth 10 | Out-File $OutputPath -Encoding utf8
        Write-Host "Metrics saved to $OutputPath"
    } catch {
        Write-Warning "Failed to save metrics to '$OutputPath': $($_.Exception.Message)"
    }

    return $metrics
}

function Get-MetricsSummary {
    [CmdletBinding()]
    param ()

    if (-not $Global:MetricsSession) {
        return "No metrics session active."
    }

    $endTime = if ($Global:MetricsSession.EndTime) { $Global:MetricsSession.EndTime } else { (Get-Date).ToUniversalTime() }
    $elapsed = ($endTime - $Global:MetricsSession.StartTime).TotalSeconds
    $totalTokens = Get-TotalTokens
    $costGBP = Get-CurrentCostGBP

    $iterationStarts = ($Global:MetricsEvents | Where-Object { $_.Type -eq "iteration_start" }).Count
    $patchesGenerated = ($Global:MetricsEvents | Where-Object { $_.Type -eq "patch_generated" }).Count
    $agentCalls = ($Global:MetricsEvents | Where-Object { $_.Type -eq "agent_call" }).Count

    $testRuns = $Global:MetricsEvents | Where-Object { $_.Type -eq "test_run" }
    $testsFixed = 0
    foreach ($tr in $testRuns) {
        if ($tr.Data -and $tr.Data.ContainsKey("testsFixed")) {
            $testsFixed += [int]$tr.Data["testsFixed"]
        }
    }

    $buildResults = $Global:MetricsEvents | Where-Object { $_.Type -eq "build_result" }
    $buildSuccesses = ($buildResults | Where-Object { $_.Data -and $_.Data["success"] -eq $true }).Count
    $buildFailures = ($buildResults | Where-Object { $_.Data -and $_.Data["success"] -eq $false }).Count

    $minutes = [Math]::Floor($elapsed / 60)
    $seconds = [Math]::Round($elapsed % 60)

    $summary = @"
=== Forge Run Metrics ===
Session:      $($Global:MetricsSession.SessionId)
Duration:     ${minutes}m ${seconds}s
Iterations:   $iterationStarts
Agent calls:  $agentCalls
Tokens used:  $($totalTokens.ToString("N0")) (prompt: $($Global:PromptTokens.ToString("N0")), completion: $($Global:CompletionTokens.ToString("N0")))
Cost:         $([string]::Format("{0:C4}", $costGBP)) GBP
Patches:      $patchesGenerated generated
Tests fixed:  $testsFixed
Builds:       $buildSuccesses passed, $buildFailures failed
"@

    return $summary
}

function Save-SuccessMetrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$RepoName,
        [string]$MemoryRoot = (Join-Path $PSScriptRoot ".." "memory")
    )

    if (-not $Global:MetricsSession) {
        Write-Warning "Metrics not initialized. Call Initialize-Metrics first."
        return
    }

    $endTime = if ($Global:MetricsSession.EndTime) { $Global:MetricsSession.EndTime } else { (Get-Date).ToUniversalTime() }
    $elapsed = ($endTime - $Global:MetricsSession.StartTime).TotalSeconds
    $totalTokens = Get-TotalTokens
    $costGBP = Get-CurrentCostGBP

    $iterationStarts = ($Global:MetricsEvents | Where-Object { $_.Type -eq "iteration_start" }).Count

    # Identify common failure patterns
    $failurePatterns = @()
    $buildFailures = $Global:MetricsEvents | Where-Object { $_.Type -eq "build_result" -and $_.Data -and $_.Data["success"] -eq $false }
    foreach ($failure in $buildFailures) {
        if ($failure.Data.ContainsKey("error")) {
            $failurePatterns += $failure.Data["error"]
        }
    }

    # Determine overall success
    $lastBuild = $Global:MetricsEvents | Where-Object { $_.Type -eq "build_result" } | Select-Object -Last 1
    $overallSuccess = if ($lastBuild -and $lastBuild.Data -and $lastBuild.Data["success"] -eq $true) { $true } else { $false }

    $dateStr = (Get-Date).ToString("yyyy-MM-dd")
    $metricsDir = Join-Path $MemoryRoot $RepoName "metrics"

    $successMetric = @{
        date              = $dateStr
        sessionId         = $Global:MetricsSession.SessionId
        success           = $overallSuccess
        iterationsToComplete = $iterationStarts
        totalTimeSeconds  = [Math]::Round($elapsed, 2)
        tokensUsed        = $totalTokens
        costGBP           = [Math]::Round($costGBP, 4)
        failurePatterns   = $failurePatterns
        costPerFix        = if ($overallSuccess -and $iterationStarts -gt 0) { [Math]::Round($costGBP / $iterationStarts, 4) } else { 0 }
    }

    try {
        if (-not (Test-Path $metricsDir)) {
            New-Item -ItemType Directory -Path $metricsDir -Force | Out-Null
        }

        $filePath = Join-Path $metricsDir "$dateStr.json"

        # If a file for this date already exists, append to an array
        $existingData = @()
        if (Test-Path $filePath) {
            try {
                $raw = Get-Content $filePath -Raw | ConvertFrom-Json
                if ($raw -is [array]) {
                    $existingData = @($raw)
                } else {
                    $existingData = @($raw)
                }
            } catch {
                Write-Warning "Failed to read existing metrics file, overwriting: $($_.Exception.Message)"
            }
        }

        $existingData += $successMetric
        $existingData | ConvertTo-Json -Depth 10 | Out-File $filePath -Encoding utf8

        Write-Host "Success metrics saved to $filePath"
    } catch {
        Write-Warning "Failed to save success metrics for '$RepoName': $($_.Exception.Message)"
    }
}

function Get-SuccessHistory {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$RepoName,
        [int]$LastN = 10,
        [string]$MemoryRoot = (Join-Path $PSScriptRoot ".." "memory")
    )

    $metricsDir = Join-Path $MemoryRoot $RepoName "metrics"

    if (-not (Test-Path $metricsDir)) {
        Write-Warning "No metrics found for repo '$RepoName' in $metricsDir"
        return @()
    }

    $allMetrics = @()

    try {
        $files = Get-ChildItem -Path $metricsDir -Filter "*.json" -File | Sort-Object Name -Descending

        foreach ($file in $files) {
            try {
                $raw = Get-Content $file.FullName -Raw | ConvertFrom-Json
                if ($raw -is [array]) {
                    $allMetrics += $raw
                } else {
                    $allMetrics += $raw
                }
            } catch {
                Write-Warning "Failed to parse metrics file '$($file.Name)': $($_.Exception.Message)"
            }

            if ($allMetrics.Count -ge $LastN) {
                break
            }
        }
    } catch {
        Write-Warning "Failed to read metrics directory for '$RepoName': $($_.Exception.Message)"
        return @()
    }

    # Return only the most recent N entries
    if ($allMetrics.Count -gt $LastN) {
        $allMetrics = $allMetrics | Select-Object -First $LastN
    }

    return $allMetrics
}

function Get-SuccessTrend {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$RepoName,
        [string]$MemoryRoot = (Join-Path $PSScriptRoot ".." "memory")
    )

    $history = Get-SuccessHistory -RepoName $RepoName -LastN 10 -MemoryRoot $MemoryRoot

    if (-not $history -or $history.Count -lt 2) {
        return @{
            Trend       = "insufficient_data"
            Description = "Not enough historical data to determine trend (need at least 2 runs)."
            RunCount    = if ($history) { $history.Count } else { 0 }
        }
    }

    # Calculate success rate for recent half vs older half
    $midpoint = [Math]::Floor($history.Count / 2)
    $recentRuns = $history | Select-Object -First $midpoint
    $olderRuns = $history | Select-Object -Skip $midpoint

    $recentSuccessRate = if ($recentRuns.Count -gt 0) {
        ($recentRuns | Where-Object { $_.success -eq $true }).Count / $recentRuns.Count
    } else { 0 }

    $olderSuccessRate = if ($olderRuns.Count -gt 0) {
        ($olderRuns | Where-Object { $_.success -eq $true }).Count / $olderRuns.Count
    } else { 0 }

    # Calculate average cost trend
    $recentAvgCost = if ($recentRuns.Count -gt 0) {
        ($recentRuns | ForEach-Object { $_.costGBP } | Measure-Object -Average).Average
    } else { 0 }

    $olderAvgCost = if ($olderRuns.Count -gt 0) {
        ($olderRuns | ForEach-Object { $_.costGBP } | Measure-Object -Average).Average
    } else { 0 }

    # Determine trend direction
    $successDelta = $recentSuccessRate - $olderSuccessRate
    $trend = if ($successDelta -gt 0.1) {
        "improving"
    } elseif ($successDelta -lt -0.1) {
        "degrading"
    } else {
        "stable"
    }

    $overallSuccessRate = ($history | Where-Object { $_.success -eq $true }).Count / $history.Count

    return @{
        Trend              = $trend
        Description        = "Success rate is $trend. Recent: $([Math]::Round($recentSuccessRate * 100, 1))%, Older: $([Math]::Round($olderSuccessRate * 100, 1))%"
        RunCount           = $history.Count
        OverallSuccessRate = [Math]::Round($overallSuccessRate * 100, 1)
        RecentSuccessRate  = [Math]::Round($recentSuccessRate * 100, 1)
        OlderSuccessRate   = [Math]::Round($olderSuccessRate * 100, 1)
        RecentAvgCostGBP   = [Math]::Round($recentAvgCost, 4)
        OlderAvgCostGBP    = [Math]::Round($olderAvgCost, 4)
    }
}

function Export-MetricsHtml {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$Metrics,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $successRateColor = if ($Metrics.successRate -ge 80) { "#28a745" } elseif ($Metrics.successRate -ge 50) { "#ffc107" } else { "#dc3545" }

    $eventsHtml = ""
    if ($Metrics.events) {
        foreach ($event in $Metrics.events) {
            $dataJson = if ($event.Data) { ($event.Data | ConvertTo-Json -Depth 5 -Compress) } else { "{}" }
            $eventsHtml += "        <tr><td>$($event.Timestamp)</td><td>$($event.Type)</td><td><code>$([System.Web.HttpUtility]::HtmlEncode($dataJson))</code></td></tr>`n"
        }
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Forge Run Metrics — $($Metrics.sessionId)</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 40px; background: #f8f9fa; color: #333; }
        h1 { color: #212529; border-bottom: 2px solid #dee2e6; padding-bottom: 10px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin: 24px 0; }
        .card { background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .card h3 { margin: 0 0 8px 0; font-size: 14px; color: #6c757d; text-transform: uppercase; }
        .card .value { font-size: 28px; font-weight: bold; color: #212529; }
        .card .unit { font-size: 14px; color: #6c757d; }
        .success-rate { color: $successRateColor; }
        table { width: 100%; border-collapse: collapse; margin-top: 24px; background: white; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        th { background: #343a40; color: white; padding: 12px; text-align: left; }
        td { padding: 10px 12px; border-bottom: 1px solid #dee2e6; font-size: 13px; }
        td code { background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 12px; }
        tr:hover { background: #f8f9fa; }
        .footer { margin-top: 32px; color: #6c757d; font-size: 12px; }
    </style>
</head>
<body>
    <h1>Forge Run Metrics</h1>
    <p>Session: <code>$($Metrics.sessionId)</code></p>
    <p>$($Metrics.startTime) to $($Metrics.endTime)</p>

    <div class="summary">
        <div class="card">
            <h3>Duration</h3>
            <div class="value">$([Math]::Round($Metrics.totalTimeSeconds / 60, 1))<span class="unit"> min</span></div>
        </div>
        <div class="card">
            <h3>Iterations</h3>
            <div class="value">$($Metrics.iterationsUsed)</div>
        </div>
        <div class="card">
            <h3>Tokens Used</h3>
            <div class="value">$($Metrics.tokensConsumed.ToString("N0"))</div>
        </div>
        <div class="card">
            <h3>Cost</h3>
            <div class="value">$([string]::Format("{0:N4}", $Metrics.costGBP))<span class="unit"> GBP</span></div>
        </div>
        <div class="card">
            <h3>Patches Tried</h3>
            <div class="value">$($Metrics.patchesTried)</div>
        </div>
        <div class="card">
            <h3>Tests Fixed</h3>
            <div class="value">$($Metrics.testsFixed)</div>
        </div>
        <div class="card">
            <h3>Success Rate</h3>
            <div class="value success-rate">$($Metrics.successRate)<span class="unit">%</span></div>
        </div>
    </div>

    <h2>Event Log</h2>
    <table>
        <thead>
            <tr><th>Timestamp</th><th>Type</th><th>Data</th></tr>
        </thead>
        <tbody>
$eventsHtml
        </tbody>
    </table>

    <div class="footer">
        Generated by Forge CLI MetricsTracker
    </div>
</body>
</html>
"@

    try {
        $dir = Split-Path $OutputPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        $html | Out-File $OutputPath -Encoding utf8
        Write-Host "HTML metrics report saved to $OutputPath"
    } catch {
        Write-Warning "Failed to export HTML metrics to '$OutputPath': $($_.Exception.Message)"
    }
}
